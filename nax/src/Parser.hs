module Parser where

import Names
import Syntax 
import BaseTypes
import Terms(applyE,expTuple,listExp,truePat,falsePat
            ,patTuple,consExp,nilExp,binop)
import Value(preDefinedDeclStrings)

-- import Types(listT,tunit,pairT,tarr,predefinedTyCon,kindOf
--             ,toTyp,tupleT,arrT,applyT,showK,showT,nat)

import qualified System.IO

import Data.List(groupBy)

import Data.Char(digitToInt,isUpper)

import Control.Monad.State

-- These are for defining parsers
import Text.Parsec hiding (State)
import Text.Parsec.Expr(Operator(..),Assoc(..),buildExpressionParser)
-- Replaces Text.Parsec.Token
import qualified Language.Trellys.LayoutToken as Token

import Debug.Trace

-- import qualified System.IO.Error -- Deprecated
import qualified Control.Exception  -- use this instead

-----------------------------------------------
-- running parsers

runMParser parser parserState name tokens stateState =
  evalState (runParserT parser parserState name tokens) stateState

parse1 file x s = runMParser (whiteSp >> x) initColumns file s initState

parseWithName file x s =
  case parse1 file x s of
   Right(ans) -> ans
   Left message -> error (show message)
   
parse2 x s = parseWithName "keyboard input" x s   

parse3 p s = putStrLn (show state) >> return object
  where (object,state) = parse2 (do { x <- p; st <- getState; return(x,st)}) s
    
parseString x s =
  case parse1 s x s of
   Right(ans) -> return ans
   Left message -> fail (show message)   

-- A special parser-transformer for seeing what input is left

-- observeSuffix x = 
--   (do { a <- x; (col,tabs,left) <- getInfo; return(a,col,tabs,take 20 left)})

-- ps x s = parse2 (observeSuffix x) s

parseFile parser file =
    do possible <- Control.Exception.try (readFile file)
                   -- System.IO.Error.tryIOError (readFile file)
       case possible of
         Right contents -> 
            case parse1 file parser contents of
              Right ans -> return ans
              Left message -> error(show message)
         Left err -> error(show (err::IOError))

--------------------------------------------         
-- Internal state and the type of parsers

type InternalState = ([(String, Typ)]   -- Map of a name of a TyCon and the TyCon (which includes its kind)
                     ,[(Name,Kind)])    -- Map of a TyVar to its kind

initState = (predefinedTyCon,[])
initColumns = []

-- use (updateState,setState,getState) to access state

traceP p = do { ((c,vs),_) <- getState; ans <- p; ((d,us),_) <- getState
              ; trace ("In  "++show c++"\nOut "++show d) (return ans)}          
  
type MParser a = ParsecT
                    String                -- The input is a sequence of Char
                    [Column]              -- The internal state for Layout tabs
                    (State InternalState) -- The other internal state: type and kind mappings
                    a                     -- the type of the object being parsed

-- Based on zombie-trellys/src/Language/Trellys/Parser.hs:
--
-- Based on Parsec's haskellStyle (which we can not use directly since
-- Parsec gives it a too specific type).
-- lbStyle :: (Stream s m Char, Monad m) => Token.GenLanguageDef s u m
lbStyle = Token.LanguageDef
                { Token.commentStart   = "{-"
                , Token.commentEnd     = "-}"
                , Token.commentLine    = "--"
                , Token.nestedComments = True
--                , Token.identStart     = letter
                , Token.identStart     = lower
                , Token.identLetter    = alphaNum <|> oneOf "_'"
                , Token.opStart        = oneOf ":!#$%&*+./<=>?@\\^|-~"
                , Token.opLetter       = oneOf ":!#$%&*+./<=>?@\\^|-~"
                , Token.caseSensitive  = True
                , Token.reservedOpNames =
                  ["!","?","\\",":",".", "<", "=", "+", "-", "^", "()", "_", "@"]
                , Token.reservedNames  = 
                  ["if","then","else"
                  ,"case","of"
                  ,"let","in"
                  ,"data"
                  ,"gadt"
                  ,"axiom"
                  ,"synonym"
                  ,"mcata","mhist","mprim","msfcata","msfprim","mprsi"
                  ,"where"
                  ,"with"
                  ,"Mu","In"
                  ,"forall"
                  ,"deriving"
                  ,"check"
                  ,"poly"
                  ]
                }
                      
(funlog,Token.LayFun layout) = Token.makeTokenParser lbStyle "{" ";" "}"

lexemE p    = Token.lexeme funlog p
arrow       = lexemE(string "->")
larrow      = lexemE(string "<-")
dot         = lexemE(char '.')
-- under       = char '_'
parenS p    = between (symboL "(") (symboL ")") p
braceS p    = between (symboL "{") (symboL "}") p
bracketS p  = between (symboL "[") (symboL "]") p
symboL      = Token.symbol funlog
natural     = lexemE(number 10 digit)
whiteSp     = Token.whiteSpace funlog
ident       = Token.identifier funlog
sym         = Token.symbol funlog
keyword     = Token.reserved funlog
commA       = Token.comma funlog
resOp       = Token.reservedOp funlog
oper        = Token.operator funlog
exactly s   = do { t <- ident; if s==t then return s else unexpected("Not the exact name: "++show s)}

number ::  Integer -> MParser Char -> MParser Integer
number base baseDigit
    = do{ digits <- many1 baseDigit
        ; let n = foldl (\x d -> base*x + toInteger (digitToInt d)) 0 digits
        ; seq n (return n)
        }
        
-------------------- Names and identifiers --------------------------

-- conName :: MParser String
conName = Token.lexeme funlog (try construct)
  where construct = do{ c <- upper
                      ; cs <- many (Token.identLetter lbStyle)
                      ; if (c:cs) == "Mu" 
                           then fail "Mu"
                           else return(c:cs)}
                    <?> "Constructor name"
                    
nameP = do { pos <- getPosition; x <- ident; return(Nm(x,pos))}
conP = do { pos <- getPosition; x <- conName; return(Nm(x,pos))}

patvariable :: MParser Pat
patvariable = 
  do { x <- nameP
     ; let result = (PVar x Nothing)
     ; let (patname@(init:_)) = name x
     ; if isUpper init
          then fail ("pattern bindings must be lowercase, but this is not: " ++ patname)
          else return result}

expvariable  :: MParser Expr               
expvariable = escape <|> (do { s <- nameP; return(EVar s)})
  where escape = do { char '`'; s <- nameP; return(EFree s)}
        

expconstructor  :: MParser Expr
expconstructor = do { nm <- conP; return(ECon nm) }
    -- pos <- getPosition; s <- conName; return(EVar (Nm(s,pos)))}
      
kindvariable  :: MParser Kind               
kindvariable = do { s <- nameP; return(Kname s)}

tycon = do { c <- conP; (name2Typ c)}  

badpolykind = PolyK [] badkind
badkind = Tarr (TyCon None (toName "BadKIND") (PolyK [] Star)) Star

-- name2Typ (Nm("Nat",_)) = return nat
name2Typ (name@(Nm(c,_))) = return (TyCon None name (badpolykind))
typevariable = do { nm <- nameP; return(TyVar nm (badkind)) }        
        
---------------------------------------------------------
-- Parsers for Literals

signed p = do { f <- sign; x <- p; return(f x) }
  where sign = (char '~' >> return negate) <|>
               (return id)   
               
chrLit  = do{ c <- Token.charLiteral funlog; return (LChar c) }
doubleLit = do { n <- (signed (Token.float funlog)); return(LDouble n)}
intLit = do{ c <- (signed Parser.natural); return (LInt (fromInteger c)) }
strLit = do{ pos <- getPosition
           ; s <- Token.stringLiteral funlog
           ; let f c = ELit pos (LChar c)
           ; return(listExp pos (map f s))}
 
literal :: MParser Literal
literal = Token.lexeme funlog
   (try doubleLit)  <|>  -- float before natP or 123.45 leaves the .45
   (try intLit)     <|>  -- try or a "-" always expects digit, and won't fail, "->"
   -- (try strLit)     <|>
   chrLit           <?> "literal"

--------------------- Parsing Patterns ----------------------------

simplePattern :: MParser Pat
simplePattern =
        try annPat
    <|> tuplePattern
    <|> (do { pos <- getPosition; x <- literal; return(PLit pos x)}) 
    <|> (do { pos <- getPosition; sym "_"; return (PWild pos)})
    <|> (do { nm <- conP; return(PCon nm []) })
 --   <|> listPattern  -- in mendler this matches with In so must be forbidden
    <|> patvariable
    <?> "simple pattern"

annPat = parenS typing
  where typing = do { p <- pattern; sym ":"; t <- sch; return(PAnn p t)}
        sch = try scheme <|> (do { r <- rhoP; return(Sch [] r)})

tuplePattern = 
  do { xs <- parenS(sepBy pattern (commA))
     ; return(patTuple xs) 
     }

conApp =
   (do { nm <- conP 
       ; ps <- many simplePattern
       ; return(PCon nm ps)})

pattern :: MParser Pat
pattern = conApp
  <|> simplePattern
  <?> "pattern"

-------------------------------------------------------------

------------------------------------------------------
-- Defining Infix and Prefix operators
-- See  "opList"  in Syntax.hs

operatorTable :: [[Operator String [Column] (State InternalState) Expr]]
operatorTable = opList prefix infiX    

prefix :: String -> Operator String [Column] (State InternalState) Expr
prefix name = Prefix(do{ try (resOp name); exp2exp name })   
  where -- exp2exp:: String -> Expr -> Expr
        exp2exp "~" = return neg
        exp2exp other = fail ("Unknown prefix operator: "++other)
        neg (ELit p (LInt x)) = ELit p (LInt (negate x))
        neg (ELit p (LDouble x)) = ELit p (LDouble (negate x))
        neg x = (EApp (EVar (Nm("negate",prelude))) x)

infiX nam assoc = 
   Infix (do{ pos <- getPosition; try (resOp nam); exp2exp2exp pos nam}) assoc
  where exp2exp2exp loc ":" = do { p <- getPosition; return (consExp p)}
        exp2exp2exp loc "$" = return (\ x y -> EApp x y)
        exp2exp2exp loc nam = return (binop (Nm(nam,loc)))

infixExpression:: MParser Expr
infixExpression =  buildExpressionParser operatorTable applyExpression

-- f x (3+4) 9
applyExpression:: MParser Expr
applyExpression =
    do{ exprs <- many1 simpleExpression
      ; return (applyE exprs)
      }  
      
-------------------------------
simpleExpression :: MParser Expr
simpleExpression = 
        parenExpression           -- (+) () (x) (x,y,z)
    <|> literalP                  -- 23.5   'x'   `d  123  #34 45n  
    <|> strLit                    -- "abc"
    <|> listExpression            -- [2,3,4]
    <|> caseExpression            -- case e of {p -> e; ...}
    <|> mendlerExp
    <|> expconstructor            -- a constructor name like "Node" or "Cons"
    <|> expvariable               -- names come last
    <?> "simple expression"

-- 23.5   123  "abc"  ()
literalP = do { loc <- getPosition; x <- literal; return(ELit loc x)}

-- (,)
pairOper :: MParser Expr
pairOper = do { l <- getPosition
              ; parenS commA
              ; return (EAbs ElimConst
                             [(PVar (Nm("_x",l)) Nothing
                              ,EAbs ElimConst
                                    [(PVar (Nm("_y",l)) Nothing
                                     ,ETuple[EVar (Nm("_x",l)),EVar (Nm("_y",l))])])])}
                                     
-- (+), (* 5) (3 +) (,) etc
section :: MParser Expr
section = try operator <|> try left <|> try right <|> try pairOper
  where operator = (do { l <- getPosition
                       ; sym "("; z <- oper; sym ")"
                       ; return (EAbs ElimConst
                                      [(PVar (Nm("_x",l)) Nothing
                                      ,EAbs ElimConst
                                            [(PVar (Nm("_y",l)) Nothing
                                             ,applyE [EVar (Nm(z,l))
                                                     ,EVar (Nm("_x",l))
                                                     ,EVar (Nm("_y",l))] )])])})
        left =(do { l <- getPosition
                  ; sym "("; z <- oper; y <- expr; sym ")"
                  ; return (EAbs ElimConst
                                 [(PVar (Nm("_x",l)) Nothing
                                  ,applyE [EVar (Nm(z,l)), EVar (Nm("_x",l)) ,y])])})
        right = (do { l <- getPosition
                    ; sym "("; y <- simpleExpression; z <- oper; sym ")"
                    ; return (EAbs ElimConst
                                   [(PVar (Nm("_x",l)) Nothing
                                   ,applyE [EVar (Nm(z,l)),y,EVar (Nm("_x",l))])])})
                                   
-- () (x) (x,y,z) (+) (+ 3) (3 *) (,) etc
parenExpression ::  MParser Expr
parenExpression = try section <|> tuple  
  where tuple = 
          do { xs <- parenS(sepBy expr (commA))
             ; return(expTuple xs)}                                
                                                  
listParser:: (MParser x) -> (SourcePos -> x -> x -> x) -> (SourcePos -> x) -> MParser x
listParser p cons nil = (try empty) <|> bracketS many
  where empty = do { g <- getPosition; sym "["; sym "]"; return (nil g)}
        last = (sym ";" >> p) <|> (do { loc <- getPosition; return(nil loc)})
        one = do { x <- p; loc <- getPosition; return(x,loc)}
        consWithPos (x,p) xs = cons p x xs
        many = do { xs <- sepBy one (sym ",") 
                  ; z <- last
                  ; return(foldr consWithPos z xs) }

-- [2,3,4] [x;xs] [x,3,x+5;zs]
listExpression :: MParser Expr
listExpression = listParser expr consExp nilExp
                  
-- [2,3,4]  list patterns imply use of 'out'
-- listPattern = 
--   do { xs <- brackets funlog (sepBy pattern (commA))
--      ; return(pConsUp patNil xs)
--      }
-- Same with infix Cons
-- infixPattern =
--  do { p1 <- try conApp <|> simplePattern
--                    --  E.g. "(L x : xs)" should parse as ((L x) : xs) rather than (L(x:xs))
--     ; x <- sym ":"
--     ; pos <- getPosition; 
--     ; p2 <- pattern
--     ; return (PCon (Nm(x,pos)) [p1,p2]) }                  
                  

{-
-- This version parsed comprehensions, No longer used     
listExpressionT = (try empty) <|> (do { sym "["; x <- expr; tail x })
  where empty = do { loc <- getPosition; sym "["; sym "]"; return (listExp loc [])}
        tail x = more x -- <|> count x <|> comp x
        more x = (do { loc <- getPosition; sym "]"; return(listExp loc[x])}) <|>
                 (do { xs <- many (sym "," >> expr)
                     ; loc <- getPosition 
                     ; sym "]"
                     ; return(listExp loc (x:xs))})
                     
        count i = do { sym ".."; j <- expr; sym "]"
                     ; return(EComp(Range i j))}
        comp x = do { sym "|"
                    ; xs <- sepBy bind (symboL ",")
                    ; sym "]"
                    ; return(EComp(Comp x xs))}
        bind = try gen <|> fmap Pred expr
        gen = do { p <- pattern
                 ; sym "<-"
                 ; e <- expr
                 ; return(Generator p e)}
-}                             
     
     
-- \ x -> f x
lambdaExpression :: MParser Expr
lambdaExpression =
    do{ resOp "\\"
      ; e2 <- elim nameP
      ; xs <- layout arm (return ())
      ; return(EAbs e2 xs) }

arm:: MParser (Pat,Expr)
arm = do { pat <- pattern
         ; sym "->"
         ; e <- expr
         ; return(pat,e) }     

-- if x then y else z
ifExpression :: MParser Expr
ifExpression =
   do { keyword "if"
      ; e1 <- expr
      ; keyword "then"
      ; l1 <- getPosition
      ; e2 <- expr
      ; keyword "else"
      ; l2 <- getPosition
      ; e3 <- expr
      ; return(EApp (EAbs ElimConst [(truePat,e2),(falsePat,e3)]) e1)
      }
      
-- case e of { p -> body; ... }
caseExpression:: MParser Expr
caseExpression =
    do{ keyword "case"
      ; e2 <- elim nameP
      ; arg <- expr
      ; keyword "of"
      ; alts <- layout arm (return ())
      ; return(EApp (EAbs e2 alts) arg)
      }      

inExpression =
  do { f <- inP; x <- expr; return(f x)}
  
---------------------- Parsing Expr ---------------------------
e1 = parse2 expr "(123,34.5,\"abc\",())"
e2 = parse2 expr "if x then (4+5) else 0"
e3 = parse2 expr "case x of\n   D x -> 5\n   C y -> y+1"
e4 = parse2 expr "\\ C x -> 4\n  D y -> g 7 y"
e5 = parse2 expr "\\ x -> \\ y -> x+ y"

expr :: MParser Expr
expr =  lambdaExpression
--     <|> letExpression
    <|> ifExpression
    <|> inExpression
    <|> annotateExpr
    <|> infixExpression     --names last
    <?> "expression"

annotateExpr = 
  do { a <- annot
     ; e <- expr
     ; return(EAnn a e)}

------------------------------------------
-- Note, other than data declarations all decls
-- start with:  --  pat* =  ...

decl:: MParser (Decl Expr)
decl = -- (datadec <|> gadtdec <|> synP <|> dec) <?> "decl"
       (axiomP <|> genericData <|> synP <|> dec) <?> "decl"
       
axiomP = 
  do { pos <- getPosition
     ; keyword "axiom" 
     ; n <- nameP
     ; sym ":"
     ; typ <- typP
     ; return(Axiom pos n typ)}
     

synP =   
  do { pos <- getPosition
     ; keyword "synonym"
     ; nm <- conP
     -- just to parse   synonym Vec a {n} = ...
     -- TODO it parses it but does not distinguish from  synonym Vec a n = ...
     -- so type inference still doesn't work for index argument variables.
     -- Maybe we need to change the definition of the Synonym data constructor
     ; xs <- many (braceS nameP <|> nameP)
     ; sym "="
     ; body <- typP -- typT (fmap Pattern (braceS pattern))  -- typPat
     ; return(Synonym pos nm xs body) }


data Post = Colon | Equality | Args [Name]
  deriving Show


genericData:: MParser(Decl Expr)
genericData = do { pos <- getPosition; keyword "data"
                 ; nm <- conP; p <- post
                 ; case p of
                     Colon -> gadtF pos nm
                     Equality -> dataF pos nm []
                     Args xs -> dataF pos nm xs }
  where post = (sym ":" >> return Colon) <|>
               (sym "=" >> return Equality) <|>
               (do { xs <- many1 nameP; sym "="; return(Args xs)})
        gadtF pos nm = 
           do { k <- kindP
              ; keyword "where"
              ; cs <- layout (constr2) (keyword "deriving" <|> return ())
              ; ds <- sepBy derivation (sym ",")
              ; return(GADT pos nm k cs ds)}
        dataF pos nm args = 
           do { cs <- sepBy constr (sym "|")
              ; ds <- derivs
              ; return(DataDec pos nm args cs ds) }
  
     
{-
-- datadec2:: MParser Decl
datadec = 
  do { pos <- getPosition
     ; keyword "data"
     ; nm <- conP
     ; let kinding = parenS explicit <|> implicit
           implicit = do { nm <- nameP; return(nm,Star)}
           explicit = do { v <- nameP ; sym "::"; k <- kindP; return (v,k)}
     ; args <- many kinding
     ; sym "=" 
     ; ((ts,vs),cols) <- getState
   
     ; cs <- sepBy constr (sym "|")
     ; ds <- derivs
     ; let ans = (DataDec pos nm (map fst args) cs ds)
  
     ; return ans } 
     
gadtdec = 
  do { pos <- getPosition
     ; keyword "gadt"
     ; nm <- conP
     ; sym ":"
     ; alls <- (do { keyword "forall"
                   ; zs <- sepBy nameP (sym ",")
                   ; sym "."; return zs})  <|> (return [])
     ; k <- kindP
     ; keyword "where"
    -- ; (old@((ts,vs),cols)) <- getState
    -- ; setState (((name nm,TyVar nm k):ts,vs),cols)  
     ; cs <- layout (constr2) (keyword "deriving" <|> return ())
     ; ds <- sepBy derivation (sym ",")
     ; return(GADT pos nm alls k cs ds)}
-}

derivs = (do { keyword "deriving"; sepBy derivation (sym ",") }) <|> return []
derivation = do { sym "fixpoint"; fmap Fixpoint conName }

constr2 =
  do { c <- conP
     ; sym ":"
     ; (schs,rho) <- rhoParts
     ; return(c,[] {- map fst freeTs -},schs,rho)}
     
     

constr =
  do { c <- conP;
     ; xs <- many sch
     ; return(c,xs) }     

sch = try (parenS scheme) <|> (do { x <- simpleTypP; return(Sch [] (Tau x))})

ex1 = (parse2 scheme "forall a b c . IO (a -> b) -> IO a -> IO (b,c)")

ex2 = mapM (parse3 decl) preDefinedDeclStrings
ex3 = parse3 (genericData >> genericData) 
       "data F x (z:: * -> *) = C (z x) | D Integer x | E (forall (x::*) . z x)\ndata T = T  (F Integer)"

    
dec = do { pos <- getPosition
         ; lhs <- many1 simplePattern
         ; resOp "=" 
         ; case lhs of
            ((PVar f _ : (p:ps))) -> 
                do { body <- expr; return(FunDec pos (name f) [] [(p:ps,body)]) }
            ([p]) -> do { b <- expr; return(Def pos p b) }
            ((PCon c []):ps) ->  do { b<- expr; return(Def pos (PCon c ps) b)} }

program = do { whiteSp
             ; ds <- layoutDecl (return ())
             ; eof
             ; return (Prog ds)}

layoutDecl endtag = do { ds <- layout decl endtag
                       ; return(map merge (groupBy sameName ds)) }
  where sameName (FunDec p n _ _) (FunDec q m _ _) = n==m
        sameName _ _ = False
        merge:: [Decl Expr] -> Decl Expr
        merge [d] = d
        merge ((FunDec pos name ts ws):ms) = FunDec pos name ts (ws++ concat(map g ms))
        g (FunDec pos name ts ws) = ws
       

------------------------------------------------

---------------------------------------------------
-- parsing types have embedded terms, These terms
-- can be either (Parsed Expr) or (Pattern Pat)
-- simpleT, muT, typT, simpleKindT take a parser 
-- that specializes for a particular embedded Term.

simpleTypP :: MParser Typ
simpleTypP  = simpleT     (fmap Parsed (braceS expr))
typP        = typT        (fmap Parsed (braceS expr))
muP         = muT         (fmap Parsed (braceS expr))
simplekindP = simplekindT (fmap Parsed (braceS expr))
firstOrderP = firstOrderT (fmap Parsed (braceS expr))
kindP       = kindT       (fmap Parsed (braceS expr))

--typPat = 
--  do { ty <- typT (fmap Pattern (braceS pattern))
--     ; return(toPat ty)}

simpleT p = muT p <|> tycon <|> typevariable <|> special <|> parenS inside  <|> fmap TyLift p
  where inside = fmap pairs (sepBy (typT p) (Token.comma funlog))        
        pairs [] = tunit
        pairs [x] = x
        pairs (x:xs) = TyTuple Star (x:xs) -- pairT x (pairs xs)
        special = -- (try (sym "(,)") >> return tpair) <|>
                  -- (try (sym "(->)") >> return tarr) <|>
                  -- (try (sym "[]") >> return tlist)  <|>
                  (fmap listT (Token.brackets funlog (typT p)))
                                       
-- typP :: MParser Typ

typT p = fmap arrow (sepBy1 (fmap applyT (many1 (simpleT p))) (sym "->"))
  where arrow [x] = x
        arrow (x:xs) = arrT x (arrow xs)
        

muT p = do { keyword "Mu"; (k,mt) <- bracketS(stuff p); return(TyMu k mt)}
  where stuff p = do { k <- kindT p
                     ; mt <- (do { sym ";"; t <- typT p; return(Just t)}) <|>
                             (return Nothing)
                     ; return(k,mt)}

inP = do { keyword "In"; k <- bracketS kindP ; return(EIn k)}

firstOrderT p = muApp <|> tyConApp 
  where tyConApp = do { m <- tycon
                      ; ts <- many (simpleT p)
                      ; return (applyT (m:ts)) }
        muApp = do { m <- muT p
                   ; t <- construct
                   ; ts <- many (simpleT p)
                   ; return(applyT (m:t:ts))}
        construct = tycon <|> parenS tyConApp
   
---------------------------------------------------------    

simplekindT p = fmap (const Star) (sym "*") <|> 
              kindvariable <|>
              try (parenS (kindT p))
              
kindArrElem p = fmap Left (simplekindT p)    <|>
                fmap Right (braceS (typT p)) <|>
                fmap Right (firstOrderT p)  
              
kindT p = do { klist <- (sepBy1 (kindArrElem p) (sym "->"))
             ; case last klist of
                 Right x -> unexpected ("lifted type at end of kind arrow chain: {"++show x++"}")
                 Left _ -> return(arrow klist) }
  where arrow [Left x] = x
        arrow (Left x : xs) = Karr x (arrow xs)
        arrow (Right x: xs) = Tarr x (arrow xs)
  
scheme = do { sym "forall"
            ; vs <- many1 kinding
            ; sym "."
            ; t <- typP
            ; return (Sch vs (Tau t))}
  where kinding = fmap lift nameP <|> parenS colon
        colon = do { v <- nameP ; sym "::"; k <- kindP; return (v,Type k)}
        lift x = (x,Type Star)


simpleRho = try (parenS scheme) <|> (do { t <- (fmap applyT (many1 simpleTypP)); return(Sch [] (Tau t))})

rhoP = do { ss <- sepBy1 simpleRho (sym "->")
          ; let g [Sch [] rho] = rho
                g [t@(Sch (v:vs) rho)] = error ("Scheme as final type of Rho: "++show t)
                g (s:ss) = Rarr s (g ss)
          ; return(g ss)}
          
rhoParts = 
  do { ss <- sepBy1 simpleRho (sym "->")
     ; let g [Sch [] rho] = ([],rho)
           g [t@(Sch (v:vs) rho)] = error ("Scheme as final type of Rho: "++show t)
           g (s:ss) = (s:xs,r) where (xs,r) = g ss
     ; return(g ss)}
--------------------------------------------------------

elim:: MParser x -> MParser (Elim [x])
elim xP = (do { sym "{"; more}) <|> return ElimConst
  where more = do { ns <- many1 xP
                  ; sym "."
                 -- ; ((ts,us),cols) <- getState
                 -- ; setState ((ts,(map (\ x -> (x,Star)) ns)++us),cols)
                  ; t <- typP
                 -- ; setState ((ts,us),cols)
                  ; sym "}"
                  ;return(ElimFun ns t)}

--------------------------------------------------------
annot = (keyword "check"  >> return CheckT)   <|> 
        (keyword "poly"   >> return Poly )   <?> "annotation"

mendlerOp = (keyword "mcata"   >> return "mcata")   <|> 
            (keyword "mhist"   >> return "mhist")   <|>
            (keyword "mprim"   >> return "mprim")   <|>
            (keyword "msfcata" >> return "msfcata") <|>
            (keyword "mprsi"   >> return "mprsi")   <|>            
            (keyword "msfprim" >> return "msfprim") <?> "mendler operator"
            
mendlerExp =
  do { s <- mendlerOp
     ; e1 <- elim simpleTypP
     ; arg <- expr
     ; keyword "with"
     ; ms <- layout mclause (return ())
     ; return(EMend s e1 arg ms)}
     
mclause = 
  do { ps <- many1 simplePattern
     ; sym "="
     ; b <- expr
     ; return(ps,b)}
     
ex5 = (parseFile program "tests/data.men")     

parseExpr s = parseString expr s
