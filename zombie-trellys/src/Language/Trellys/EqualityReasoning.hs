{-# LANGUAGE StandaloneDeriving, TemplateHaskell, ScopedTypeVariables,
    FlexibleInstances, MultiParamTypeClasses, FlexibleContexts,
    GeneralizedNewtypeDeriving, ViewPatterns,
    UndecidableInstances, OverlappingInstances, TypeSynonymInstances, 
    TupleSections, TypeFamilies #-}

module Language.Trellys.EqualityReasoning (prove, uneraseTerm, zonkTerm, zonkTele) where

import Generics.RepLib hiding (Arrow,Con,Refl)
import qualified Generics.RepLib as RL
import Language.Trellys.GenericBind 

import Language.Trellys.TypeMonad
import Language.Trellys.Syntax
import Language.Trellys.Environment(UniVarBindings, setUniVars)
import Language.Trellys.OpSem(erase)
import Language.Trellys.CongruenceClosure

import Control.Arrow (first, second, Kleisli(..), runKleisli)
import Control.Applicative 
import Control.Monad.Writer.Lazy (WriterT, runWriterT, tell )
import Control.Monad.ST
import Control.Monad.State.Strict
import Data.Maybe (isJust,fromJust)
import qualified Data.Set as S
import Data.Set (Set)
import Data.List (intercalate)
import qualified Data.Map as M
import Data.Map (Map)
import Data.Function (on)
import Data.Ix
import Data.Bimap (Bimap)
import qualified Data.Bimap as BM

--Stuff used for debugging.
import Language.Trellys.PrettyPrint
import Text.PrettyPrint.HughesPJ ( (<>), (<+>),hsep,text, parens, brackets, render)
import Debug.Trace

-- A convenient monad for recording an association between terms and constants.
-- While we are at it, also record what free unification variables various terms have.
newtype NamingT t m a = NamingT (StateT (--record the mapping
                                         Bimap t Constant,
                                         --list of already allocated constants, and they unification variables.
                                         [(Constant,Maybe AName,Set AName)],
                                         --supply of fresh constants
                                         [Constant]) 
                                        m a)
  deriving (Monad, MonadTrans, Functor, Applicative)

instance Fresh m => Fresh (NamingT t m) where
  fresh = lift . fresh

recordName :: (Monad m, Ord t) => t -> Maybe AName -> Set AName -> NamingT t m Constant
recordName t x evars = 
    NamingT $ do
               (mapping, allocated, (c:cs)) <- get
               case BM.lookup t mapping of
                 Nothing -> do put (BM.insert t c mapping, (c,x,evars):allocated, cs)
                               return c
                 Just c' -> return c'

runNamingT :: (Monad m) => NamingT t m a -> [Constant] -> m (a, Bimap t Constant, [(Constant,Maybe AName, Set AName)])
runNamingT (NamingT m) constantSupply = do
  (a, (mapping, touchable, supply)) <- runStateT m (BM.empty, [], constantSupply) 
  return (a, mapping, touchable)

type TermLabel = Bind [(AName,Epsilon)] ATerm

instance Eq TermLabel where
  (==) = aeq
instance Ord TermLabel where
  compare = acompare

-- This data type just records the operations that the congruence closure algorithm 
-- performs. It is useful to construct this intermediate structure so that we don't have
-- to traverse the proof multiple times when pushing in Symm
data RawProof =
   --The first component is either Just a proof term which the type elaborator constructed
   -- (usually just a variable, sometimes unbox applied to a variable),
   -- or Nothing if an equality holds just by (join) after erasure.
   RawAssumption (Maybe ATerm, ATerm, ATerm) 
 | RawRefl
 | RawSymm RawProof
 | RawTrans RawProof RawProof
 | RawCong TermLabel [RawProof]
  deriving (Show,Eq)

$(derive [''RawProof])

instance Proof RawProof where
  type Label RawProof = TermLabel
  type CName RawProof = AName
  refl _ = RawRefl
  symm = RawSymm
  trans = RawTrans 
  cong = RawCong 

-- ********** ASSOCIATION PHASE 
-- In a first pass, we associate all uses of trans to the right, which
-- lets us simplify subproofs of the form (trans h (trans (symm h) p))
-- to just p. (This is done by the rawTrans helper function).
-- This is important because such ineffecient proofs are
-- often introduced by the union-find datastructure.

associateProof :: RawProof -> RawProof
associateProof (RawAssumption h) = RawAssumption h
associateProof RawRefl = RawRefl
associateProof (RawSymm p) = RawSymm (associateProof p)
associateProof (RawTrans p q) = rawTrans (associateProof p) (associateProof q)
associateProof (RawCong l ps) = RawCong l (map associateProof ps)

-- This is a smart constructor for RawTrans
rawTrans :: RawProof -> RawProof -> RawProof
rawTrans RawRefl p = p
rawTrans (RawTrans p q) r = maybeCancel p (rawTrans q r)
  where maybeCancel :: RawProof -> RawProof -> RawProof
        maybeCancel p           (RawTrans (RawSymm q) r) | p==q = r
        maybeCancel (RawSymm p) (RawTrans q r)           | p==q = r
        maybeCancel p q = RawTrans p q
rawTrans p q = RawTrans p q

-- ********** SYMMETRIZATION PHASE
-- Next we simplify the RawProofs into this datatype, which gets rid of
-- the Symm constructor by pushing it up to the leaves of the tree.

data Orientation = Swapped | NotSwapped
  deriving (Show,Eq)
data Raw1Proof =
   Raw1Assumption Orientation (Maybe ATerm, ATerm, ATerm)
 | Raw1Refl
 | Raw1Trans Raw1Proof Raw1Proof
 | Raw1Cong TermLabel [Raw1Proof]
  deriving Show

symmetrizeProof :: RawProof -> Raw1Proof
symmetrizeProof (RawAssumption h) = Raw1Assumption NotSwapped h
symmetrizeProof (RawSymm (RawAssumption h)) = Raw1Assumption Swapped h
symmetrizeProof RawRefl = Raw1Refl
symmetrizeProof (RawSymm RawRefl) = Raw1Refl
symmetrizeProof (RawSymm (RawSymm p)) = symmetrizeProof p
symmetrizeProof (RawTrans p q) = Raw1Trans (symmetrizeProof p) (symmetrizeProof q)
symmetrizeProof (RawSymm (RawTrans p q)) = Raw1Trans (symmetrizeProof (RawSymm q))
                                                     (symmetrizeProof (RawSymm p))
symmetrizeProof (RawCong l ps) = Raw1Cong l (map symmetrizeProof ps)
symmetrizeProof (RawSymm (RawCong l ps)) = Raw1Cong l (map (symmetrizeProof . RawSymm) ps)

-- ********** NORMALIZATION PHASE
-- The raw1 proof terms are then normalized into this datatype, by
-- associating transitivity to the right and fusing adjacent Congs. 
-- A SynthProof lets you infer the lhs of the equality it is proving,
-- while a CheckProof doesn't.

data SynthProof =
    AssumTrans Orientation (Maybe ATerm,ATerm,ATerm) CheckProof
  deriving Show
data CheckProof =
    Synth SynthProof
  | Refl
  | Cong ATerm [(AName, Maybe CheckProof)]
  | CongTrans ATerm [(AName, Maybe CheckProof)] SynthProof
 deriving Show

transProof :: CheckProof -> CheckProof -> CheckProof
transProof (Synth (AssumTrans o h p)) q = Synth (AssumTrans o h (transProof p q))
transProof Refl q = q
transProof (Cong l ps) (Synth q) = CongTrans l ps q
transProof (Cong l ps) Refl = Cong l ps
transProof (Cong l ps) (Cong _ qs) = Cong l (zipWith transSubproof ps qs)
transProof (Cong l ps) (CongTrans _ qs r) = CongTrans l (zipWith transSubproof ps qs) r
transProof (CongTrans l ps (AssumTrans o h q)) r =  CongTrans l ps (AssumTrans o h (transProof q r))

transSubproof :: (AName, Maybe CheckProof) -> (AName, Maybe CheckProof) -> (AName, Maybe CheckProof)
transSubproof (x,Nothing) (_,Nothing) = (x, Nothing)
transSubproof (x,Just p)  (_,Just q)  = (x, Just $ transProof p q)

fuseProof :: (Applicative m, Fresh m)=> Raw1Proof -> m CheckProof
fuseProof (Raw1Assumption o h) = return $ Synth (AssumTrans o h Refl)
fuseProof (Raw1Refl) = return $ Refl
fuseProof (Raw1Trans Raw1Refl q) = fuseProof q
fuseProof (Raw1Trans (Raw1Assumption o h) q) =  Synth . AssumTrans o h <$> (fuseProof q)
fuseProof (Raw1Trans (Raw1Trans p q) r) = fuseProof (Raw1Trans p (Raw1Trans q r))
fuseProof (Raw1Trans (Raw1Cong bnd ps) q) = do
  (xs, template) <- unbind bnd
  ps' <- fuseProofs xs ps
  q0' <- fuseProof q
  case q0' of
    Synth q'            -> return $ CongTrans template ps' q'
    Refl                -> return $ Cong      template ps'
    (Cong _ qs')        -> return $ Cong      template (zipWith transSubproof ps' qs')
    (CongTrans _ qs' r) -> return $ CongTrans template (zipWith transSubproof ps' qs') r
fuseProof (Raw1Cong bnd ps) = do
  (xs, template) <- unbind bnd  
  Cong template <$> fuseProofs xs ps

fuseProofs :: (Applicative m, Fresh m) => [(AName,Epsilon)] -> [Raw1Proof] -> m [(AName,Maybe CheckProof)]
fuseProofs [] [] = return []
fuseProofs ((x,Runtime):xs) (p:ps) =  do
  p' <- fuseProof p
  ps' <- fuseProofs xs ps
  return $ (x,Just p'):ps'
fuseProofs ((x,Erased):xs) ps =  do
  ps' <- fuseProofs xs ps
  return $ (x, Nothing):ps'

-- ************ ANNOTATION PHASE
-- Having normalized the proof, in the next phase we annotate it by all the subterms involved.

data AnnotProof = 
    AnnAssum Orientation (Maybe ATerm,ATerm,ATerm)
  | AnnRefl ATerm ATerm
  | AnnCong ATerm [(AName,ATerm,ATerm,Maybe AnnotProof)]
  | AnnTrans ATerm ATerm ATerm AnnotProof AnnotProof
 deriving Show

-- [synthProof B p] takes a SynthProof of A=B and returns A and the corresponding AnnotProof
synthProof :: (Applicative m, Fresh m) => ATerm -> SynthProof -> m (ATerm,AnnotProof)
synthProof tyB (AssumTrans NotSwapped h@(n,tyA,tyC) p) = do
  q <- checkProof tyC tyB p
  return $ (tyA, AnnTrans tyA tyC tyB (AnnAssum NotSwapped h) q)
synthProof tyB (AssumTrans Swapped    h@(n,tyA,tyC) p) = do
  q <- checkProof tyA tyB p
  return $ (tyC, AnnTrans tyC tyA tyB(AnnAssum Swapped h) q)

-- [checkProof A B p] takes a CheckProof of A=B and returns a corresponding AnnotProof
checkProof :: (Applicative m, Fresh m) => ATerm -> ATerm -> CheckProof -> m AnnotProof
checkProof _ tyB (Synth p) = snd <$> synthProof tyB p
checkProof tyA tyB Refl = return $ AnnRefl tyA tyB
checkProof tyA tyB (Cong template ps)  =  do
  subAs <- match (map (\(x,_)->x) ps) template tyA
  subBs <- match (map (\(x,_)->x) ps) template tyB
  subpfs <- mapM (\(x,mp) -> let subA = fromJust $ M.lookup x subAs
                                 subB = fromJust $ M.lookup x subBs
                             in case mp of 
                                  Nothing -> return (x,subA,subB,Nothing)
                                  Just p -> do
                                              p' <- checkProof subA subB p
                                              return (x, subA, subB, Just p'))
                 ps
  return $ AnnCong template subpfs
checkProof tyA tyC (CongTrans template ps q)  = do
  (tyB, tq) <- synthProof tyC q
  subAs <- match (map (\(x,_)->x) ps) template tyA
  subBs <- match (map (\(x,_)->x) ps) template tyB
  subpfs <- mapM (\(x,mp) -> let subA = fromJust $ M.lookup x subAs
                                 subB = fromJust $ M.lookup x subBs
                             in case mp of 
                                  Nothing -> return (x,subA,subB,Nothing)
                                  Just p -> do
                                              p' <- checkProof subA subB p
                                              return (x, subA, subB, Just p'))
                 ps
  return $ AnnTrans tyA tyB tyC
            (AnnCong template subpfs)
            tq

-- generate AnnotProof's for a list of equations [ep,tyA,tyB]
checkProofs :: (Applicative m, Fresh m) =>
                [(Epsilon, ATerm, ATerm)] -> [CheckProof] -> m [(ATerm,ATerm,Maybe AnnotProof)]
checkProofs [] [] = return []
checkProofs ((Runtime,tyA,tyB):goals) (p:ps) = do
  pt <- checkProof tyA tyB p
  ((tyA, tyB, Just pt) :) <$>  (checkProofs goals ps)
checkProofs ((Erased,tyA,tyB):goals) ps =
  ((tyA, tyB, Nothing) :) <$> (checkProofs goals ps)

-- ************* SIMPLIFICATION PHASE
-- We simplify the annotated proof by merging any two adjacent Congs into a single one,
-- and merging Congs and Refls.

simplProof ::  AnnotProof -> AnnotProof
simplProof p@(AnnAssum _ _) = p
simplProof p@(AnnRefl _ _) = p
simplProof (AnnTrans tyA tyB tyC p q) = AnnTrans tyA tyB tyC (simplProof p) (simplProof q)
simplProof (AnnCong template ps) =  let (template', ps') = simplCong (template,[]) ps 
                                    in (AnnCong template' ps')
  where simplCong (t, acc) [] = (t, reverse acc)
        simplCong (t, acc) ((x,tyA,tyB,_):ps) | tyA `aeq` tyB = 
           simplCong (subst x tyA t, acc) ps
        simplCong (t, acc) ((x,tyA,_,Just (AnnRefl _ _)):ps) = 
           simplCong (subst x tyA t, acc) ps
        simplCong (t, acc) ((x,tyA,tyB,Just (AnnCong subT subPs)):ps) =
           simplCong (subst x subT t, acc) (subPs++ps)
        simplCong (t, acc) (p:ps) = simplCong (t, p:acc) ps


-- ************* TERM GENERATION PHASE
-- Final pass: now we can generate the Trellys Core proof terms.

genProofTerm :: (Applicative m, Fresh m) => AnnotProof -> m ATerm
genProofTerm (AnnAssum NotSwapped (Just a,tyA,tyB)) = return $ a
genProofTerm (AnnAssum Swapped (Just a,tyA,tyB)) = symmTerm tyA tyB a
genProofTerm (AnnAssum NotSwapped (Nothing,tyA,tyB)) = return $ AJoin tyA 0 tyB 0
genProofTerm (AnnAssum Swapped    (Nothing,tyA,tyB)) = return $ AJoin tyB 0 tyA 0
genProofTerm (AnnRefl tyA tyB) =   return (AJoin tyA 0 tyB 0)
genProofTerm (AnnCong template ps) = do
  let tyA = substs (map (\(x,subA,subB,_) -> (x,subA)) ps) template
  let tyB = substs (map (\(x,subA,subB,_) -> (x,subB)) ps) template
  subpfs <- mapM (\(x,subA,subB,p) -> case p of 
                                      Nothing -> return (ATyEq subA subB, Erased)
                                      Just p' -> (,Runtime) <$> genProofTerm p')
                 ps                                            
  return (AConv (AJoin tyA 0 tyA 0)
                subpfs
                (bind (map (\(x,_,_,_) -> x) ps) (ATyEq tyA template))
                (ATyEq tyA tyB))
genProofTerm (AnnTrans tyA tyB tyC p q) = do
  p' <- genProofTerm p
  q' <- genProofTerm q
  transTerm tyA tyB tyC p' q'

-- From (tyA=tyB) and (tyB=tyC), conclude (tyA=tyC).
transTerm :: Fresh m => ATerm -> ATerm -> ATerm -> ATerm -> ATerm -> m ATerm
transTerm tyA tyB tyC p q = do
  x <- fresh (string2Name "x")
  return $ AConv p [(q,Runtime)] (bind [x] (ATyEq tyA (AVar x))) (ATyEq tyA tyC)

-- From (tyA=tyB) conclude (tyA=tyB), but in a way that only uses the
-- hypothesis in an erased position.
uneraseTerm :: (Fresh m,Applicative m) => ATerm -> ATerm -> ATerm -> m ATerm
uneraseTerm tyA tyB p = do
  x <- fresh (string2Name "x")
  -- As an optimization, if the proof term already has no free unerased variables we can just use it as-is.
  pErased <- erase p
  if S.null (fv pErased :: Set EName)
    then return p
    else return $ AConv (AJoin tyA 0 tyA 0) [(p,Runtime)] (bind [x] (ATyEq tyA (AVar x))) (ATyEq tyA tyB)

-- From (tyA=tyB) conlude (tyB=tyA).
symmTerm :: Fresh m => ATerm -> ATerm -> ATerm -> m ATerm
symmTerm tyA tyB p = do
  x <- fresh (string2Name "x")
  return $ AConv (AJoin tyA 0 tyA 0) [(p,Runtime)] (bind [x] (ATyEq (AVar x) tyA)) (ATyEq tyB tyA)

orEps :: Epsilon -> Epsilon -> Epsilon
orEps Erased _ = Erased
orEps _ Erased = Erased
orEps Runtime Runtime = Runtime

----------------------------------------
-- Dealing with unification variables.
----------------------------------------

-- | To zonk a term (this word comes from GHC) means to replace all occurances of 
-- unification variables with their definitions.
zonkTerm :: (Applicative m, MonadState UniVarBindings m) => ATerm -> m ATerm
zonkTerm a = do
  bindings <- get
  return $ zonkWithBindings bindings a

zonkTele :: (Applicative m, MonadState UniVarBindings m) => ATelescope -> m ATelescope
zonkTele tele = do
  bindings <- get
  return $ zonkWithBindings bindings tele

zonkWithBindings :: Rep a => UniVarBindings -> a -> a
zonkWithBindings bindings = RL.everywhere (RL.mkT zonkTermOnce)
  where zonkTermOnce :: ATerm -> ATerm
        zonkTermOnce (AUniVar x ty) = case M.lookup x bindings of
                                        Nothing -> (AUniVar x ty)
                                        Just a -> zonkWithBindings bindings a
        zonkTermOnce a = a


-- | Gather all unification variables that occur in a term.
uniVars :: ATerm -> Set AName 
uniVars = RL.everything S.union (RL.mkQ S.empty uniVarsHere) 
  where uniVarsHere (AUniVar x _)   = S.singleton x
        uniVarsHere  _ = S.empty

-- 'decompose False avoid t' returns a new term 's' where each immediate
-- subterm of 't' that does not mention any of the variables in 'avoid'
-- has been replaced by a fresh variable. The mapping of the
-- introduced fresh variables is recorded in the writer monad, along with whether
-- the variable occurs in an unerased position or not.
-- The boolean argument tracks whether we are looking at a subterm or at the original term,
-- the epsilon tracks whether we are looking at a subterm in an erased position of the original term.

decompose :: (Monad m, Applicative m, Fresh m) => 
             Bool -> Epsilon -> Set AName -> ATerm -> WriterT [(Epsilon,AName,ATerm)] m ATerm
decompose True e avoid t | S.null (S.intersection avoid (fv t)) = do
  x <- fresh (string2Name "x")
  tell [(e, x, t)]
  return $ AVar x
decompose _ _ avoid t@(AVar _) = return t
decompose _ _ avoid t@(AUniVar _ _) = return t
decompose sub e avoid (ACumul t l) = ACumul <$> (decompose True e avoid t) <*> pure l
decompose _ _ avoid t@(AType _) = return t
decompose sub e avoid (ATCon c args) = do
  args' <- mapM (decompose True e avoid) args
  return $ ATCon c args'
decompose sub e avoid (ADCon c params args) = do
  params' <- mapM (decompose True Erased avoid) params
  args' <- mapM (\(a,ep) -> (,ep) <$> (decompose True (e `orEps` ep) avoid a)) args
  return $ ADCon c params' args'
decompose _ e avoid (AArrow ex ep bnd) = do
  ((x,unembed->t1), t2) <- unbind bnd
  r1 <- decompose True e avoid t1
  r2 <- decompose True e (S.insert x avoid) t2
  return (AArrow ex ep (bind (x, embed r1) r2))
decompose _ e avoid (ALam ty ep bnd) = do
  (x, body) <- unbind bnd 
  ty' <- decompose True Erased avoid ty
  r <- decompose True e (S.insert x avoid) body
  return (ALam ty' ep (bind x r))
decompose _ e avoid (AApp ep t1 t2 ty) = 
  AApp ep <$> (decompose True e avoid t1) 
          <*> (decompose True (e `orEps` ep) avoid t2)
          <*> (decompose True Erased avoid ty)
decompose sub e avoid (AAt t th) =
  AAt <$> (decompose True e avoid t) <*> pure th
decompose sub e avoid (AUnboxVal t) = AUnboxVal <$> (decompose True e avoid t)
decompose sub e avoid (ABox t th) = ABox <$> (decompose True e avoid t) <*> pure th
decompose _ e avoid (AAbort t) = AAbort <$> (decompose True Erased avoid t)
decompose _ e avoid (ATyEq t1 t2) =
  ATyEq <$> (decompose True e avoid t1) <*> (decompose True e avoid t2)
--Fixme: surely we need to do something about the erased subterms here?
decompose _ _ avoid t@(AJoin a i b j) =
  AJoin <$> (decompose True Erased avoid a) <*> pure i 
        <*> (decompose True Erased avoid b) <*> pure j
decompose _ e avoid (AConv t1 ts bnd ty) =  do
  (xs, t2) <- unbind bnd
  r1 <- decompose True e avoid t1
  rs <- mapM (firstM $ decompose True Erased avoid) ts
  r2 <- decompose True Erased (S.union (S.fromList xs) avoid) t2
  ty' <- decompose True Erased avoid ty
  return (AConv r1 rs (bind xs r2) ty')
decompose _ e avoid (AContra t ty) = 
  AContra <$> (decompose True Erased avoid t) <*> (decompose True Erased avoid ty)
decompose _ e avoid (AInjDCon a i) =
  AInjDCon <$> (decompose True e avoid a) <*> pure i
decompose _ e avoid (ASmaller t1 t2) =
  ASmaller <$> (decompose True e avoid t1) <*> (decompose True e avoid t2)
decompose _ e avoid (AOrdAx t1 t2) =
  AOrdAx <$> (decompose True e avoid t1) <*> (decompose True Erased avoid t2)
decompose _ e avoid (AOrdTrans t1 t2) =
  AOrdTrans <$>  (decompose True e avoid t1) <*> (decompose True e avoid t2)
decompose _ e avoid (AInd ty ep bnd) = do
  ((x,y), t) <- unbind bnd
  ty' <- decompose True Erased avoid ty
  r <- decompose True e (S.insert x (S.insert y avoid)) t
  return $ AInd ty' ep (bind (x,y) r)  
decompose _ e avoid (ARec ty ep bnd) = do
  ((x,y), t) <- unbind bnd
  ty' <- decompose True Erased avoid ty
  r <- decompose True e (S.insert x (S.insert y avoid)) t
  return $ ARec ty' ep (bind (x,y) r)
decompose _ e avoid (ALet ep bnd) = do
  ((x,y, unembed->t1), t2) <- unbind bnd
  r1 <- decompose True (e `orEps` ep) avoid t1
  r2 <- decompose True e (S.insert x (S.insert y avoid)) t2
  return $ ALet ep (bind (x,y, embed r1) r2)
decompose _ e avoid (ACase t1 bnd ty) = do
  (x, ms) <- unbind bnd
  ty' <- decompose True Erased avoid ty
  r1 <- decompose True e avoid t1
  rs <- mapM (decomposeMatch e (S.insert x avoid)) ms
  return (ACase r1 (bind x rs) ty')
decompose _ _ avoid (ATrustMe t) = 
  ATrustMe <$> (decompose True Erased avoid t)
decompose _ e avoid (ASubstitutedFor t x) =
  ASubstitutedFor <$> (decompose True e avoid t) <*> pure x

decomposeMatch :: (Monad m, Applicative m, Fresh m) => 
                  Epsilon -> Set AName -> AMatch -> WriterT [(Epsilon,AName,ATerm)] m AMatch
decomposeMatch e avoid (AMatch c bnd) = do
  (args, t) <- unbind bnd
  r <- (decompose True e (S.union (binders args) avoid) t)
  return $ AMatch c (bind args r)

-- | match is kind of the opposite of decompose: 
--   [match vars template t] returns the substitution s of terms for the variables in var,
--   such that (substs (toList (match vars template t)) template) == t
-- Precondition: t should actually be a substitution instance of template, with those vars.

match :: (Applicative m, Monad m, Fresh m) => 
         [AName] -> ATerm -> ATerm -> m (Map AName ATerm)
match vars (AVar x) t | x `elem` vars = return $ M.singleton x t
                      | otherwise     = return M.empty
match vars (AUniVar _ _) (AUniVar _ _) = return M.empty
match vars (ACumul t _) (ACumul t' _) = match vars t t'
match vars (AType _) _ = return M.empty
match vars (ATCon c params) (ATCon _ params') = 
  foldr M.union M.empty <$> zipWithM (match vars) params params'
match vars (ADCon c params ts) (ADCon _ params' ts') = do
   m1 <- foldr M.union M.empty <$> zipWithM (match vars) params params'
   m2 <- foldr M.union M.empty <$> zipWithM (match vars `on` fst) ts ts'
   return (m1 `M.union` m2)
match vars (AArrow ex ep bnd) (AArrow ex' ep' bnd') = do
  Just ((_,unembed -> t1), t2, (_,unembed -> t1'), t2') <- unbind2 bnd bnd'
  match vars t1 t1' `mUnion` match vars t2 t2'
--Fixme: think a bit about ty.
match vars (ALam ty ep bnd) (ALam ty' ep' bnd') = do
  Just (_, t, _, t') <- unbind2 bnd bnd'
  match vars ty ty' `mUnion` match vars t t'
match vars (AApp ep t1 t2 ty) (AApp ep' t1' t2' ty') =
  match vars t1 t1' 
   `mUnion` match vars t2 t2'
   `mUnion` match vars ty ty'
match vars (AAt t _) (AAt t' _) = match vars t t'
match vars (AUnboxVal t) (AUnboxVal t') = match vars t t'
match vars (ABox t th) (ABox t' th') = match vars t t'
match vars (AAbort t) (AAbort t') = match vars t t'
match vars (ATyEq t1 t2) (ATyEq t1' t2') =
  match vars t1 t1' `mUnion` match vars t2 t2'
--Fixme: this seems dubious too?
match vars (AJoin a _ b _) (AJoin a' _ b' _) = 
  match vars a a' `mUnion` match vars b b'
match vars (AConv t1 t2s bnd ty) (AConv t1' t2s' bnd' ty') = do
  Just (_, t3, _, t3') <- unbind2 bnd bnd'
  match vars t1 t1'
   `mUnion` (foldr M.union M.empty <$> zipWithM (match vars `on` fst) t2s t2s')
   `mUnion` match vars t3 t3'
   `mUnion` match vars ty ty'
match vars (AContra t1 t2) (AContra t1' t2') =
  match vars t1 t1' `mUnion` match vars t2 t2'
match vars (AInjDCon a i) (AInjDCon a' i') = 
  match vars a a'
match vars (ASmaller t1 t2) (ASmaller t1' t2') =
  match vars t1 t1' `mUnion` match vars t2 t2'
match vars (AOrdAx t1 t2) (AOrdAx t1' t2') = 
  match vars t1 t1' `mUnion` match vars t2 t2'
match vars (AOrdTrans t1 t2) (AOrdTrans t1' t2') =
  match vars t1 t1' `mUnion` match vars t2 t2'
match vars (AInd ty ep bnd) (AInd ty' ep' bnd') = do
  Just ((_,_), t, (_,_), t') <- unbind2 bnd bnd'
  match vars ty ty' `mUnion` match vars t t'
match vars (ARec ty ep bnd) (ARec ty' ep' bnd') = do
  Just ((_,_), t, (_,_), t') <- unbind2 bnd bnd'
  match vars ty ty' `mUnion` match vars t t'
match vars (ALet ep bnd) (ALet ep' bnd') = do
  Just ((_,_,unembed -> t1), t2, (_,_,unembed -> t1'), t2') <- unbind2 bnd bnd'
  match vars t1 t1' `mUnion` match vars t2 t2'
match vars (ACase t1 bnd ty) (ACase t1' bnd' ty') = do
  Just (_, alts, _, alts') <- unbind2 bnd bnd'
  (foldr M.union M.empty <$> zipWithM (matchMatch vars) alts alts')
    `mUnion`  match vars t1 t1'
    `mUnion`  match vars ty ty'
match vars (ATrustMe t) (ATrustMe t') = match vars t t'
match vars (ASubstitutedFor t _) (ASubstitutedFor t' _) = match vars t t'
match _ t t' = error $ "internal error: match called on non-matching terms "
                       ++ show t ++ " and " ++ show t' ++ "."

matchMatch :: (Applicative m, Monad m, Fresh m) =>
              [AName] -> AMatch -> AMatch -> m (Map AName ATerm)
matchMatch vars (AMatch _ bnd) (AMatch _ bnd') = do
  Just (_, t, _, t') <- unbind2 bnd bnd'
  match vars t t'

-- a short name for (union <$> _ <*> _)
mUnion :: (Applicative m, Ord k) => m (Map k a) -> m (Map k a) -> m (Map k a)
mUnion x y = M.union <$> x <*> y

-- A monad for naming subterms and recording term-subterm equations.
type DestructureT m a = WriterT [(RawProof, Equation TermLabel)] (NamingT ATerm m) a

isAUniVar :: ATerm -> Bool
isAUniVar (AUniVar _ _) = True
isAUniVar _ = False

-- Take a term to think about, and name each subterm in it as a seperate constant,
-- while at the same time recording equations relating terms to their subterms.
-- Note that erased subterms are not sent on to the congruence closure algorithm.
genEqs :: (Monad m, Applicative m, Fresh m) => ATerm -> DestructureT m Constant
genEqs t = do
  let mx = case t of 
              (AUniVar x _) -> Just (translate x)
              _             -> Nothing
  a <- lift $ recordName t mx (S.map translate (uniVars t))
  (s,ss) <- runWriterT (decompose False Runtime S.empty t)
  let ssRuntime = filter (\(ep,name,term) -> ep==Runtime) ss
  bs <- mapM genEqs (map (\(ep,name,term) -> term) $ ssRuntime)
  let label = (bind (map (\(ep,name,term)->(name,ep)) ss) s)
  tell [(RawRefl,
         Right $ EqBranchConst label bs a)]

  when (not (null ssRuntime)) $ do
    --If the head of t is erased, we record an equation saying so.
    sErased <- erase s
    let ((_,x,s1):_) = ssRuntime
    when (sErased `aeq` EVar (translate x)) $
      tell [(RawAssumption (Nothing, t, s1),
             Left $ EqConstConst a (head bs))]
  return a

runDestructureT :: (Monad m) => 
                   DestructureT m a -> m ([(RawProof, Equation TermLabel)], Bimap ATerm Constant, [(Constant,Maybe AName,Set AName)], a)
runDestructureT x = do
  ((a, eqs), bm, allocated) <- flip runNamingT constantSupply $ runWriterT x
  return (eqs, bm, allocated, a)
 where constantSupply :: [Constant]
       constantSupply = map Constant [0..]  

-- Given an assumed equation between subterms, name all the intermediate terms, and also add the equation itself.
processHyp :: (Monad m, Applicative m, Fresh m) => (ATerm, ATerm, ATerm) -> DestructureT m ()
processHyp (n,t1,t2) = do
  a1 <- genEqs t1
  a2 <- genEqs t2
  tell [(RawAssumption (Just n,t1,t2), 
         Left $ EqConstConst a1 a2)]

traceFun :: Bimap ATerm Constant -> String -> WantedEquation -> a -> a
traceFun naming msg (WantedEquation c1 c2) =
        trace (msg ++ " "    ++ (render (parens (disp (naming BM.!> c1))))
                   ++ " == " ++ (render (parens (disp (naming BM.!> c2)))))

noTraceFun :: Bimap ATerm Constant -> String -> WantedEquation -> a -> a
noTraceFun naming msg eq = id


-- "Given a list of equations, please prove the other equation."
prove :: [(ATerm,ATerm,ATerm)] -> (ATerm, ATerm) -> TcMonad (Maybe ATerm)
prove hyps (lhs, rhs) = do
  (eqs, naming, allocated, (c1,c2))  <- runDestructureT $ do
                                          mapM_ processHyp hyps
                                          c1 <- genEqs lhs
                                          c2 <- genEqs rhs
                                          return $ (c1,c2)
{-  liftIO $ do
    putStrLn $ "The available equations are:\n"
    putStrLn $ intercalate "\n" (map (render . disp) eqs)
    putStrLn $ "The equation to show is " ++ show c1 ++ " == " ++ show c2  -}
  let sts = flip execStateT (newState allocated) $ do
              propagate eqs
              unify (noTraceFun naming) S.empty [WantedEquation c1 c2]
  case sts of
    [] -> return Nothing
    st:_ -> 
       let bndgs = M.map (naming BM.!>)  (bindings st)
           pf = (proofs st) M.! (WantedEquation c1 c2) in
        do

         let zonkedAssociated = associateProof $ zonkWithBindings bndgs pf
         let symmetrized = symmetrizeProof zonkedAssociated
         fused <- fuseProof symmetrized
         checked <- checkProof lhs rhs fused
         let simplified = simplProof checked

{-
         liftIO $ putStrLn $ "Unification successful, calculated bindings " ++ show (M.map (render . disp) bndgs)
         liftIO $ putStrLn $ "Proof is: \n" ++ show pf
         liftIO $ putStrLn $ "Associated: \n" ++ show zonkedAssociated
         liftIO $ putStrLn $ "Symmetrized: \n" ++ show symmetrized
         liftIO $ putStrLn $ "Fused: \n" ++ show fused
         liftIO $ putStrLn $ "Checked: \n" ++ show checked
         liftIO $ putStrLn $ "Simplified: \n" ++ show simplified
-}
         setUniVars bndgs
         tm <- (genProofTerm 
                  <=< return . simplProof
                  <=< checkProof lhs rhs 
                  <=< fuseProof 
                  . symmetrizeProof 
                  . associateProof 
                  . zonkWithBindings bndgs) pf
         return $ Just tm

---- Some misc. utility functions

firstM :: Monad m => (a -> m b) -> (a,c) -> m (b,c)
firstM = runKleisli . first . Kleisli

instance Disp (RawProof, Equation TermLabel) where 
  disp (p, eq) = disp p <+> text ":" <+> disp eq

instance Disp RawProof where
  disp _ = text "prf"

instance Disp EqConstConst where
  disp (EqConstConst a b) = text (show a) <+> text "=" <+> text (show b)

instance Disp (EqBranchConst TermLabel) where
  disp (EqBranchConst label bs a) = parens (disp label) <+> hsep (map (text . show) bs) <+> text "=" <+> text (show a)

instance Disp TermLabel where
  disp bnd = 
   let (vars, body) = unsafeUnbind bnd in
     text "<" <> hsep (map disp vars) <> text ">." <+> disp body

instance Disp (AName, Epsilon) where
  disp (x,Runtime) = disp x
  disp (x,Erased) = brackets (disp x)
