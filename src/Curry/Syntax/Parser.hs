{- |
    Module      :  $Header$
    Description :  A Parser for Curry
    Copyright   :  (c) 1999 - 2004 Wolfgang Lux
                       2005        Martin Engelke
                       2011 - 2015 Björn Peemöller
    License     :  OtherLicense

    Maintainer  :  bjp@informatik.uni-kiel.de
    Stability   :  experimental
    Portability :  portable

    The Curry parser is implemented using the (mostly) LL(1) parsing
    combinators implemented in 'Curry.Base.LLParseComb'.
-}
{-# LANGUAGE CPP #-}
module Curry.Syntax.Parser
  ( parseSource, parseHeader, parseInterface, parseGoal
  ) where

#if __GLASGOW_HASKELL__ >= 710
import Prelude hiding ((<$>), (<*>))
#endif
import Curry.Base.Ident
import Curry.Base.Monad       (CYM)
import Curry.Base.Position    (Position, mk, mk')
import Curry.Base.LLParseComb

import Curry.Syntax.Extension
import Curry.Syntax.Lexer (Token (..), Category (..), Attributes (..), lexer)
import Curry.Syntax.Type
import Curry.Syntax.Utils (mkInt, addSrcRefs)

-- |Parse a 'Module'
parseSource :: FilePath -> String -> CYM Module
parseSource fn
  = fmap addSrcRefs
  . fullParser (uncurry <$> moduleHeader <*> layout moduleDecls) lexer fn

-- |Parse a 'Module' header
parseHeader :: FilePath -> String -> CYM Module
parseHeader
  = prefixParser (moduleHeader <*> startLayout importDecls <*> succeed []) lexer
  where importDecls = many (importDecl <*-> many semicolon)

-- |Parse an 'Interface'
parseInterface :: FilePath -> String -> CYM Interface
parseInterface = fullParser interface lexer

-- |Parse a 'Goal'
parseGoal :: String -> CYM Goal
parseGoal = fullParser goal lexer ""

-- ---------------------------------------------------------------------------
-- Module header
-- ---------------------------------------------------------------------------

-- |Parser for a module header
moduleHeader :: Parser Token ([ImportDecl] -> [Decl] -> Module) a
moduleHeader = (\ps (m, es) -> Module ps m es)
           <$> modulePragmas
           <*> header
  where header = (,) <$-> token KW_module <*> modIdent
                     <*>  option exportSpec
                     <*-> expectWhere
                `opt` (mainMIdent, Nothing)

modulePragmas :: Parser Token [ModulePragma] a
modulePragmas = many (languagePragma <|> optionsPragma)

languagePragma :: Parser Token ModulePragma a
languagePragma =   LanguagePragma
              <$>  tokenPos PragmaLanguage
              <*>  (languageExtension `sepBy1` comma)
              <*-> token PragmaEnd
  where languageExtension = classifyExtension <$> ident

optionsPragma :: Parser Token ModulePragma a
optionsPragma = (\pos a -> OptionsPragma pos (fmap classifyTool $ toolVal a)
                                             (toolArgs a))
           <$>  position
           <*>  token PragmaOptions
           <*-> token PragmaEnd

-- |Parser for an export specification
exportSpec :: Parser Token ExportSpec a
exportSpec = Exporting <$> position <*> parens (export `sepBy` comma)

-- |Parser for an export item
export :: Parser Token Export a
export =  qtycon <**> (parens spec `opt` Export)         -- type constructor
      <|> Export <$> qfun <\> qtycon                     -- fun
      <|> ExportModule <$-> token KW_module <*> modIdent -- module
  where spec =       ExportTypeAll  <$-> token DotDot
            <|> flip ExportTypeWith <$>  con `sepBy` comma

moduleDecls :: Parser Token ([ImportDecl], [Decl]) a
moduleDecls = impDecl <$> importDecl
                      <*> (semicolon <-*> moduleDecls `opt` ([], []))
          <|> (,) []  <$> topDecls
  where impDecl i (is, ds) = (i:is ,ds)

-- |Parser for a single import declaration
importDecl :: Parser Token ImportDecl a
importDecl =  flip . ImportDecl
          <$> tokenPos KW_import
          <*> flag (token Id_qualified)
          <*> modIdent
          <*> option (token Id_as <-*> modIdent)
          <*> option importSpec

-- |Parser for an import specification
importSpec :: Parser Token ImportSpec a
importSpec =   position
          <**> (Hiding <$-> token Id_hiding `opt` Importing)
          <*>  parens (spec `sepBy` comma)
  where
  spec    =  tycon <**> (parens constrs `opt` Import)
         <|> Import <$> fun <\> tycon
  constrs =  ImportTypeAll       <$-> token DotDot
         <|> flip ImportTypeWith <$>  con `sepBy` comma

-- ---------------------------------------------------------------------------
-- Interfaces
-- ---------------------------------------------------------------------------

-- |Parser for an interface
interface :: Parser Token Interface a
interface = uncurry <$> intfHeader <*> braces intfDecls

intfHeader :: Parser Token ([IImportDecl] -> [IDecl] -> Interface) a
intfHeader = Interface <$-> token Id_interface <*> modIdent <*-> expectWhere

intfDecls :: Parser Token ([IImportDecl], [IDecl]) a
intfDecls = impDecl <$> iImportDecl
                    <*> (semicolon <-*> intfDecls `opt` ([], []))
        <|> (,) [] <$> intfDecl `sepBy` semicolon
  where impDecl i (is, ds) = (i:is, ds)

-- |Parser for a single interface import declaration
iImportDecl :: Parser Token IImportDecl a
iImportDecl = IImportDecl <$> tokenPos KW_import <*> modIdent

-- |Parser for a single interface declaration
intfDecl :: Parser Token IDecl a
intfDecl = choice [ iInfixDecl, iHidingDecl, iDataDecl, iNewtypeDecl
                  , iTypeDecl , iFunctionDecl <\> token Id_hiding ]

-- |Parser for an interface infix declaration
iInfixDecl :: Parser Token IDecl a
iInfixDecl = infixDeclLhs IInfixDecl <*> integer <*> qfunop

-- |Parser for an interface hiding declaration
iHidingDecl :: Parser Token IDecl a
iHidingDecl = tokenPos Id_hiding <**> (hDataDecl <|> hFuncDecl)
  where
  hDataDecl = hiddenData <$-> token KW_data <*> qtycon <*> many tyvar
  hFuncDecl = hidingFunc <$> arity <*-> token DoubleColon <*> type0
  hiddenData tc tvs p = HidingDataDecl p tc tvs
  -- TODO: 0 was inserted to type check, but what is the meaning of this field?
  hidingFunc a ty p = IFunctionDecl p (qualify (mkIdent "hiding")) a ty

-- |Parser for an interface data declaration
iDataDecl :: Parser Token IDecl a
iDataDecl = iTypeDeclLhs IDataDecl KW_data <*> constrs <*> iHidden
  where constrs = equals <-*> constrDecl `sepBy1` bar `opt` []

-- |Parser for an interface newtype declaration
iNewtypeDecl :: Parser Token IDecl a
iNewtypeDecl = iTypeDeclLhs INewtypeDecl KW_newtype
               <*-> equals <*> newConstrDecl <*> iHidden

-- |Parser for an interface type synonym declaration
iTypeDecl :: Parser Token IDecl a
iTypeDecl = iTypeDeclLhs ITypeDecl KW_type
            <*-> equals <*> type0

-- |Parser for an interface hiding pragma
iHidden :: Parser Token [Ident] a
iHidden = token PragmaHiding
          <-*> (con `sepBy` comma)
          <*-> token PragmaEnd
          `opt` []


-- |Parser for an interface function declaration
iFunctionDecl :: Parser Token IDecl a
iFunctionDecl =  IFunctionDecl <$> position <*> qfun <*> arity
            <*-> token DoubleColon <*> type0

-- |Parser for function's arity
arity :: Parser Token Int a
arity = int `opt` 0

iTypeDeclLhs :: (Position -> QualIdent -> [Ident] -> a) -> Category
             -> Parser Token a b
iTypeDeclLhs f kw = f <$> tokenPos kw <*> qtycon <*> many tyvar

-- ---------------------------------------------------------------------------
-- Top-Level Declarations
-- ---------------------------------------------------------------------------

topDecls :: Parser Token [Decl] a
topDecls = topDecl `sepBy` semicolon

topDecl :: Parser Token Decl a
topDecl = choice [ dataDecl, newtypeDecl, typeDecl
                 , foreignDecl, infixDecl, functionDecl ]

dataDecl :: Parser Token Decl a
dataDecl = typeDeclLhs DataDecl KW_data <*> constrs
  where constrs = equals <-*> constrDecl `sepBy1` bar `opt` []

newtypeDecl :: Parser Token Decl a
newtypeDecl = typeDeclLhs NewtypeDecl KW_newtype <*-> equals <*> newConstrDecl

typeDecl :: Parser Token Decl a
typeDecl = typeDeclLhs TypeDecl KW_type <*-> equals <*> type0

typeDeclLhs :: (Position -> Ident -> [Ident] -> a) -> Category
            -> Parser Token a b
typeDeclLhs f kw = f <$> tokenPos kw <*> tycon <*> many anonOrTyvar

constrDecl :: Parser Token ConstrDecl a
constrDecl = position <**> (existVars <**> constr)
  where
  constr =  conId     <**> identDecl
        <|> leftParen <-*> parenDecl
        <|> type1 <\> conId <\> leftParen <**> opDecl
  identDecl =  many type2 <**> (conType <$> opDecl `opt` conDecl)
           <|> recDecl <$> recFields
  parenDecl =  conOpDeclPrefix
           <$> conSym    <*-> rightParen <*> type2 <*> type2
           <|> tupleType <*-> rightParen <**> opDecl
  opDecl = conOpDecl <$> conop <*> type1
  recFields                        = layoutOff <-*> braces
                                       (fieldDecl `sepBy` comma)
  conType f tys c                  = f $ ConstructorType (qualify c) tys
  conDecl tys c tvs p              = ConstrDecl p tvs c tys
  conOpDecl op ty2 ty1 tvs p       = ConOpDecl p tvs ty1 op ty2
  conOpDeclPrefix op ty1 ty2 tvs p = ConOpDecl p tvs ty1 op ty2
  recDecl fs c tvs p               = RecordDecl p tvs c fs

fieldDecl :: Parser Token FieldDecl a
fieldDecl = FieldDecl <$> position <*> labels <*-> token DoubleColon <*> type0
  where labels = fun `sepBy1` comma

newConstrDecl :: Parser Token NewConstrDecl a
newConstrDecl = position <**> (existVars <**> (con <**> newConstr))
  where newConstr =  newConDecl <$> type2
                 <|> newRecDecl <$> newFieldDecl
        newConDecl ty  c vs p = NewConstrDecl p vs c ty
        newRecDecl fld c vs p = NewRecordDecl p vs c fld

newFieldDecl :: Parser Token (Ident, TypeExpr) a
newFieldDecl = layoutOff <-*> braces labelDecl
  where labelDecl = (,) <$> fun <*-> token DoubleColon <*> type0

-- Parsing of existential variables (currently disabled)
existVars :: Parser Token [Ident] a
{-
existVars flat
  | flat = succeed []
  | otherwise = token Id_forall <-*> many1 tyvar <*-> dot `opt` []
-}
existVars = succeed []

functionDecl :: Parser Token Decl a
functionDecl = position <**> decl
  where
  decl = fun `sepBy1` comma <**> funListDecl
    <|?> mkFunDecl <$> lhs <*> declRhs
  lhs = (\f -> (f, FunLhs f [])) <$> fun <|?> funLhs

funListDecl :: Parser Token ([Ident] -> Position -> Decl) a
funListDecl =  typeSig           <$-> token DoubleColon <*> type0
           <|> flip ExternalDecl <$-> token KW_external
  where typeSig ty vs p = TypeSig p vs ty

mkFunDecl :: (Ident, Lhs) -> Rhs -> Position -> Decl
mkFunDecl (f, lhs) rhs' p = FunctionDecl p f [Equation p lhs rhs']

funLhs :: Parser Token (Ident, Lhs) a
funLhs = mkFunLhs    <$> fun      <*> many1 pattern2
    <|?> flip ($ id) <$> pattern1 <*> opLhs
    <|?> curriedLhs
  where
  opLhs  =                opLHS funSym (gConSym <\> funSym)
       <|> backquote <-*> opLHS (funId            <*-> expectBackquote)
                                (qConId <\> funId <*-> expectBackquote)
  opLHS funP consP = mkOpLhs    <$> funP  <*> pattern0
                 <|> mkInfixPat <$> consP <*> pattern1 <*> opLhs
  mkFunLhs f ts           = (f , FunLhs f ts)
  mkOpLhs op t2 f t1      = (op, OpLhs (f t1) op t2)
  mkInfixPat op t2 f g t1 = f (g . InfixPattern t1 op) t2

curriedLhs :: Parser Token (Ident,Lhs) a
curriedLhs = apLhs <$> parens funLhs <*> many1 pattern2
  where apLhs (f, lhs) ts = (f, ApLhs lhs ts)

declRhs :: Parser Token Rhs a
declRhs = rhs equals

rhs :: Parser Token a b -> Parser Token Rhs b
rhs eq = rhsExpr <*> localDecls
  where rhsExpr =  SimpleRhs  <$-> eq <*> position <*> expr
               <|> GuardedRhs <$>  many1 (condExpr eq)

localDecls :: Parser Token [Decl] a
localDecls = token KW_where <-*> layout valueDecls `opt` []

valueDecls :: Parser Token [Decl] a
valueDecls  = choice [infixDecl, valueDecl, foreignDecl] `sepBy` semicolon

infixDecl :: Parser Token Decl a
infixDecl = infixDeclLhs InfixDecl <*> option integer <*> funop `sepBy1` comma

infixDeclLhs :: (Position -> Infix -> a) -> Parser Token a b
infixDeclLhs f = f <$> position <*> tokenOps infixKW
  where infixKW = [(KW_infix, Infix), (KW_infixl, InfixL), (KW_infixr, InfixR)]

valueDecl :: Parser Token Decl a
valueDecl = position <**> decl
  where
  decl =   var `sepBy1` comma         <**> valListDecl
      <|?> patOrFunDecl <$> pattern0   <*> declRhs
      <|?> mkFunDecl    <$> curriedLhs <*> declRhs

  valListDecl = funListDecl <|> flip FreeDecl <$-> token KW_free

  patOrFunDecl (ConstructorPattern c ts)
    | not (isConstrId c) = mkFunDecl (f, FunLhs f ts)
    where f = unqualify c
  patOrFunDecl t = patOrOpDecl id t

  patOrOpDecl f (InfixPattern t1 op t2)
    | isConstrId op = patOrOpDecl (f . InfixPattern t1 op) t2
    | otherwise     = mkFunDecl (op', OpLhs (f t1) op' t2)
    where op' = unqualify op
  patOrOpDecl f t = mkPatDecl (f t)

  mkPatDecl t rhs' p = PatternDecl p t rhs'

  isConstrId c = c == qConsId || isQualified c || isQTupleId c

foreignDecl :: Parser Token Decl a
foreignDecl = ForeignDecl
          <$> tokenPos KW_foreign
          <*> callConv <*> (option string)
          <*> fun <*-> token DoubleColon <*> type0
  where callConv =  CallConvPrimitive <$-> token Id_primitive
                <|> CallConvCCall     <$-> token Id_ccall
                <?> "Unsupported calling convention"

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- type0 ::= type1 ['->' type0]
type0 :: Parser Token TypeExpr a
type0 = type1 `chainr1` (ArrowType <$-> token RightArrow)

-- type1 ::= QTyCon { type2 } | type2
type1 :: Parser Token TypeExpr a
type1 = ConstructorType <$> qtycon <*> many type2
     <|> type2 <\> qtycon

-- type2 ::= anonType | identType | parenType | listType
type2 :: Parser Token TypeExpr a
type2 = anonType <|> identType <|> parenType <|> listType

-- anonType ::= '_'
anonType :: Parser Token TypeExpr a
anonType = VariableType <$> anonIdent

-- identType ::= <identifier>
identType :: Parser Token TypeExpr a
identType = VariableType <$> tyvar
        <|> flip ConstructorType [] <$> qtycon <\> tyvar

-- parenType ::= '(' tupleType ')'
parenType :: Parser Token TypeExpr a
parenType = parens tupleType

-- tupleType ::= type0                         (parenthesized type)
--            |  type0 ',' type0 { ',' type0 } (tuple type)
--            |                                (unit type)
tupleType :: Parser Token TypeExpr a
tupleType = type0 <??> (tuple <$> many1 (comma <-*> type0))
                           `opt` TupleType []
  where tuple tys ty = TupleType (ty : tys)

-- listType ::= '[' type0 ']'
listType :: Parser Token TypeExpr a
listType = ListType <$> brackets type0

-- ---------------------------------------------------------------------------
-- Literals
-- ---------------------------------------------------------------------------

-- literal ::= '\'' <escaped character> '\''
--          |  <integer>
--          |  <float>
--          |  '"' <escaped string> '"'
literal :: Parser Token Literal a
literal = mk Char   <$> char
      <|> mkInt     <$> integer
      <|> mk Float  <$> float
      <|> mk String <$> string

-- ---------------------------------------------------------------------------
-- Patterns
-- ---------------------------------------------------------------------------

-- pattern0 ::= pattern1 [ gconop pattern0 ]
pattern0 :: Parser Token Pattern a
pattern0 = pattern1 `chainr1` (flip InfixPattern <$> gconop)

-- pattern1 ::= varId
--           |  QConId { pattern2 }
--           |  '-'  Integer
--           |  '-.' Float
--           |  '(' parenPattern'
--           | pattern2
pattern1 :: Parser Token Pattern a
pattern1 =  varId <**> identPattern'            -- unqualified
        <|> qConId <\> varId <**> constrPattern -- qualified
        <|> minus     <**> negNum
        <|> fminus    <**> negFloat
        <|> leftParen <-*> parenPattern'
        <|> pattern2  <\> qConId <\> leftParen
  where
  identPattern' =  optAsRecPattern
               <|> mkConsPattern qualify <$> many1 pattern2

  constrPattern =  mkConsPattern id <$> many1 pattern2
               <|> optRecPattern

  mkConsPattern f ts c = ConstructorPattern (f c) ts

  parenPattern' =  minus  <**> minusPattern negNum
               <|> fminus <**> minusPattern negFloat
               <|> gconPattern
               <|> funSym <\> minus <\> fminus <*-> rightParen
                                               <**> identPattern'
               <|> parenTuplePattern <\> minus <\> fminus <*-> rightParen
  minusPattern p = rightParen           <-*> identPattern' -- (-) and (-.) as variables
                <|> parenMinusPattern p <*-> rightParen
  gconPattern = ConstructorPattern <$> gconId <*-> rightParen
                                   <*> many pattern2

pattern2 :: Parser Token Pattern a
pattern2 =  literalPattern <|> anonPattern <|> identPattern
        <|> parenPattern   <|> listPattern <|> lazyPattern

-- literalPattern ::= <integer> | <char> | <float> | <string>
literalPattern :: Parser Token Pattern a
literalPattern = LiteralPattern <$> literal

-- anonPattern ::= '_'
anonPattern :: Parser Token Pattern a
anonPattern = VariablePattern <$> anonIdent

-- identPattern ::= Variable [ '@' pattern2 | '{' fields '}'
--               |  qConId   [ '{' fields '}' ]
identPattern :: Parser Token Pattern a
identPattern =  varId <**> optAsRecPattern -- unqualified
            <|> qConId <\> varId <**> optRecPattern               -- qualified

-- TODO: document me!
parenPattern :: Parser Token Pattern a
parenPattern = leftParen <-*> parenPattern'
  where
  parenPattern' = minus  <**> minusPattern negNum
              <|> fminus <**> minusPattern negFloat
              <|> flip ConstructorPattern [] <$> gconId <*-> rightParen
              <|> funSym <\> minus <\> fminus <*-> rightParen
                                              <**> optAsRecPattern
              <|> parenTuplePattern <\> minus <\> fminus <*-> rightParen
  minusPattern p = rightParen <-*> optAsRecPattern
                <|> parenMinusPattern p <*-> rightParen

-- listPattern ::= '[' pattern0s ']'
-- pattern0s   ::= {- empty -}
--              |  pattern0 ',' pattern0s
listPattern :: Parser Token Pattern a
listPattern = mk' ListPattern <$> brackets (pattern0 `sepBy` comma)

-- lazyPattern ::= '~' pattern2
lazyPattern :: Parser Token Pattern a
lazyPattern = mk LazyPattern <$-> token Tilde <*> pattern2

-- optRecPattern ::= [ '{' fields '}' ]
optRecPattern :: Parser Token (QualIdent -> Pattern) a
optRecPattern = mkRecPattern <$> fields pattern0 `opt` mkConPattern
  where
  mkRecPattern fs c = RecordPattern c fs
  mkConPattern c    = ConstructorPattern c []

-- ---------------------------------------------------------------------------
-- Partial patterns used in the combinators above, but also for parsing
-- the left-hand side of a declaration.
-- ---------------------------------------------------------------------------

gconId :: Parser Token QualIdent a
gconId = colon <|> tupleCommas

negNum :: Parser Token (Ident -> Pattern) a
negNum = flip NegativePattern <$> (mkInt <$> integer <|> mk Float <$> float)

negFloat :: Parser Token (Ident -> Pattern) a
negFloat = flip NegativePattern . mk Float
           <$> (fromIntegral <$> integer <|> float)

optAsRecPattern :: Parser Token (Ident -> Pattern) a
optAsRecPattern =  flip AsPattern <$-> token At <*> pattern2
               <|> recPattern     <$>  fields pattern0
               `opt` VariablePattern
  where recPattern fs v = RecordPattern (qualify v) fs

optInfixPattern :: Parser Token (Pattern -> Pattern) a
optInfixPattern = mkInfixPat <$> gconop <*> pattern0
            `opt` id
  where mkInfixPat op t2 t1 = InfixPattern t1 op t2

optTuplePattern :: Parser Token (Pattern -> Pattern) a
optTuplePattern = tuple <$> many1 (comma <-*> pattern0)
            `opt` ParenPattern
  where tuple ts t = mk TuplePattern (t:ts)

parenMinusPattern :: Parser Token (Ident -> Pattern) a
                  -> Parser Token (Ident -> Pattern) a
parenMinusPattern p = p <.> optInfixPattern <.> optTuplePattern

parenTuplePattern :: Parser Token Pattern a
parenTuplePattern = pattern0 <**> optTuplePattern
              `opt` mk TuplePattern []

-- ---------------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------------

-- condExpr ::= '|' expr0 eq expr
--
-- Note: The guard is an `expr0` instead of `expr` since conditional expressions
-- may also occur in case expressions, and an expression like
-- @
-- case a of { _ -> True :: Bool -> a }
-- @
-- can not be parsed with a limited parser lookahead.
condExpr :: Parser Token a b -> Parser Token CondExpr b
condExpr eq = CondExpr <$> position <*-> bar <*> expr0 <*-> eq <*> expr

-- expr ::= expr0 [ '::' type0 ]
expr :: Parser Token Expression a
expr = expr0 <??> (flip Typed <$-> token DoubleColon <*> type0)

-- expr0 ::= expr1 { infixOp expr1 }
expr0 :: Parser Token Expression a
expr0 = expr1 `chainr1` (flip InfixApply <$> infixOp)

-- expr1 ::= - expr2 | -. expr2 | expr2
expr1 :: Parser Token Expression a
expr1 =  UnaryMinus <$> (minus <|> fminus) <*> expr2
     <|> expr2

-- expr2 ::= lambdaExpr | letExpr | doExpr | ifExpr | caseExpr | expr3
expr2 :: Parser Token Expression a
expr2 = choice [ lambdaExpr, letExpr, doExpr, ifExpr, caseExpr
               , foldl1 Apply <$> many1 expr3
               ]

expr3 :: Parser Token Expression a
expr3 = foldl RecordUpdate <$> expr4 <*> many recUpdate
  where recUpdate = layoutOff <-*> braces (field expr0 `sepBy1` comma)

expr4 :: Parser Token Expression a
expr4 = choice
  [constant, anonFreeVariable, variable, parenExpr, listExpr]

constant :: Parser Token Expression a
constant = Literal <$> literal

anonFreeVariable :: Parser Token Expression a
anonFreeVariable =  (\ p v -> Variable $ qualify $ addPositionIdent p v)
                <$> position <*> anonIdent

variable :: Parser Token Expression a
variable = qFunId <**> optRecord
  where optRecord = flip Record <$> fields expr0 `opt` Variable

parenExpr :: Parser Token Expression a
parenExpr = parens pExpr
  where
  pExpr = (minus <|> fminus) <**> minusOrTuple
      <|> Constructor <$> tupleCommas
      <|> leftSectionOrTuple <\> minus <\> fminus
      <|> opOrRightSection <\> minus <\> fminus
      `opt` mk Tuple []
  minusOrTuple = flip UnaryMinus <$> expr1 <.> infixOrTuple
            `opt` Variable . qualify
  leftSectionOrTuple = expr1 <**> infixOrTuple
  infixOrTuple = ($ id) <$> infixOrTuple'
  infixOrTuple' = infixOp <**> leftSectionOrExp
              <|> (.) <$> (optType <.> tupleExpr)
  leftSectionOrExp = expr1 <**> (infixApp <$> infixOrTuple')
                `opt` leftSection
  optType   = flip Typed <$-> token DoubleColon <*> type0 `opt` id
  tupleExpr = tuple <$> many1 (comma <-*> expr) `opt` Paren
  opOrRightSection =  qFunSym <**> optRightSection
                  <|> colon   <**> optCRightSection
                  <|> infixOp <\> colon <\> qFunSym <**> rightSection
  optRightSection  = (. InfixOp    ) <$> rightSection `opt` Variable
  optCRightSection = (. InfixConstr) <$> rightSection `opt` Constructor
  rightSection     = flip RightSection <$> expr0
  infixApp f e2 op g e1 = f (g . InfixApply e1 op) e2
  leftSection op f e = LeftSection (f e) op
  tuple es e = mk Tuple (e:es)

infixOp :: Parser Token InfixOp a
infixOp = InfixOp <$> qfunop <|> InfixConstr <$> colon

listExpr :: Parser Token Expression a
listExpr = brackets (elements `opt` mk' List [])
  where
  elements = expr <**> rest
  rest = comprehension
      <|> enumeration (flip EnumFromTo) EnumFrom
      <|> comma <-*> expr <**>
          (enumeration (flip3 EnumFromThenTo) (flip EnumFromThen)
          <|> list <$> many (comma <-*> expr))
    `opt` (\e -> mk' List [e])
  comprehension = flip (mk ListCompr) <$-> bar <*> quals
  enumeration enumTo enum =
    token DotDot <-*> (enumTo <$> expr `opt` enum)
  list es e2 e1 = mk' List (e1:e2:es)
  flip3 f x y z = f z y x

lambdaExpr :: Parser Token Expression a
lambdaExpr = mk Lambda <$-> token Backslash <*> many1 pattern2
                       <*-> expectRightArrow <*> expr

letExpr :: Parser Token Expression a
letExpr = Let <$-> token KW_let <*> layout valueDecls
              <*-> (token KW_in <?> "in expected") <*> expr

doExpr :: Parser Token Expression a
doExpr = uncurry Do <$-> token KW_do <*> layout stmts

ifExpr :: Parser Token Expression a
ifExpr = mk IfThenElse
    <$-> token KW_if                         <*> expr
    <*-> (token KW_then <?> "then expected") <*> expr
    <*-> (token KW_else <?> "else expected") <*> expr

caseExpr :: Parser Token Expression a
caseExpr = keyword <*> expr
      <*-> (token KW_of <?> "of expected") <*> layout (alt `sepBy1` semicolon)
  where keyword =  mk Case Flex  <$-> token KW_fcase
               <|> mk Case Rigid <$-> token KW_case

alt :: Parser Token Alt a
alt = Alt <$> position <*> pattern0 <*> rhs expectRightArrow

fields :: Parser Token a b -> Parser Token [Field a] b
fields p = layoutOff <-*> braces (field p `sepBy` comma)

field :: Parser Token a b -> Parser Token (Field a) b
field p = Field <$> position <*> qfun <*-> expectEquals <*> p

-- ---------------------------------------------------------------------------
-- \paragraph{Statements in list comprehensions and \texttt{do} expressions}
-- Parsing statements is a bit difficult because the syntax of patterns
-- and expressions largely overlaps. The parser will first try to
-- recognize the prefix \emph{Pattern}~\texttt{<-} of a binding statement
-- and if this fails fall back into parsing an expression statement. In
-- addition, we have to be prepared that the sequence
-- \texttt{let}~\emph{LocalDefs} can be either a let-statement or the
-- prefix of a let expression.
-- ---------------------------------------------------------------------------

stmts :: Parser Token ([Statement], Expression) a
stmts = stmt reqStmts optStmts

reqStmts :: Parser Token (Statement -> ([Statement], Expression)) a
reqStmts = (\ (sts, e) st -> (st : sts, e)) <$-> semicolon <*> stmts

optStmts :: Parser Token (Expression -> ([Statement],Expression)) a
optStmts = succeed (mk StmtExpr) <.> reqStmts `opt` (,) []

quals :: Parser Token [Statement] a
quals = stmt (succeed id) (succeed $ mk StmtExpr) `sepBy1` comma

stmt :: Parser Token (Statement -> a) b
     -> Parser Token (Expression -> a) b -> Parser Token a b
stmt stmtCont exprCont =  letStmt stmtCont exprCont
                      <|> exprOrBindStmt stmtCont exprCont

letStmt :: Parser Token (Statement -> a) b
        -> Parser Token (Expression -> a) b -> Parser Token a b
letStmt stmtCont exprCont = token KW_let <-*> layout valueDecls <**> optExpr
  where optExpr =  flip Let <$-> token KW_in <*> expr <.> exprCont
               <|> succeed StmtDecl <.> stmtCont

exprOrBindStmt :: Parser Token (Statement -> a) b
               -> Parser Token (Expression -> a) b
               -> Parser Token a b
exprOrBindStmt stmtCont exprCont =
       mk StmtBind <$> pattern0 <*-> leftArrow <*> expr <**> stmtCont
  <|?> expr <\> token KW_let <**> exprCont

-- ---------------------------------------------------------------------------
-- Goals
-- ---------------------------------------------------------------------------

goal :: Parser Token Goal a
goal = Goal <$> position <*> expr <*> localDecls

-- ---------------------------------------------------------------------------
-- Literals, identifiers, and (infix) operators
-- ---------------------------------------------------------------------------

char :: Parser Token Char a
char = cval <$> token CharTok

float :: Parser Token Double a
float = fval <$> token FloatTok

int :: Parser Token Int a
int = fromInteger <$> integer

integer :: Parser Token Integer a
integer = ival <$> token IntTok

string :: Parser Token String a
string = sval <$> token StringTok

tycon :: Parser Token Ident a
tycon = conId

anonOrTyvar :: Parser Token Ident a
anonOrTyvar = anonIdent <|> tyvar

tyvar :: Parser Token Ident a
tyvar = varId

qtycon :: Parser Token QualIdent a
qtycon = qConId

varId :: Parser Token Ident a
varId = ident

funId :: Parser Token Ident a
funId = ident

conId :: Parser Token Ident a
conId = ident

funSym :: Parser Token Ident a
funSym = sym

conSym :: Parser Token Ident a
conSym = sym

modIdent :: Parser Token ModuleIdent a
modIdent = mIdent <?> "module name expected"

var :: Parser Token Ident a
var = varId <|> parens (funSym <?> "operator symbol expected")

fun :: Parser Token Ident a
fun = funId <|> parens (funSym <?> "operator symbol expected")

con :: Parser Token Ident a
con = conId <|> parens (conSym <?> "operator symbol expected")

funop :: Parser Token Ident a
funop = funSym <|> backquotes (funId <?> "operator name expected")

conop :: Parser Token Ident a
conop = conSym <|> backquotes (conId <?> "operator name expected")

qFunId :: Parser Token QualIdent a
qFunId = qIdent

qConId :: Parser Token QualIdent a
qConId = qIdent

qFunSym :: Parser Token QualIdent a
qFunSym = qSym

qConSym :: Parser Token QualIdent a
qConSym = qSym

gConSym :: Parser Token QualIdent a
gConSym = qConSym <|> colon

qfun :: Parser Token QualIdent a
qfun = qFunId <|> parens (qFunSym <?> "operator symbol expected")

qfunop :: Parser Token QualIdent a
qfunop = qFunSym <|> backquotes (qFunId <?> "operator name expected")

gconop :: Parser Token QualIdent a
gconop = gConSym <|> backquotes (qConId <?> "operator name expected")

anonIdent :: Parser Token Ident a
anonIdent = (\ p -> addPositionIdent p anonId) <$> tokenPos Underscore

mIdent :: Parser Token ModuleIdent a
mIdent = mIdent' <$> position <*>
     tokens [Id,QId,Id_as,Id_ccall,Id_forall,Id_hiding,
             Id_interface,Id_primitive,Id_qualified]
  where mIdent' p a = addPositionModuleIdent p $
                      mkMIdent (modulVal a ++ [sval a])

ident :: Parser Token Ident a
ident = (\ pos -> mkIdentPosition pos . sval) <$> position <*>
       tokens [Id,Id_as,Id_ccall,Id_forall,Id_hiding,
               Id_interface,Id_primitive,Id_qualified]

qIdent :: Parser Token QualIdent a
qIdent =  qualify  <$> ident
      <|> mkQIdent <$> position <*> token QId
  where mkQIdent p a = qualifyWith (mkMIdent (modulVal a))
                                   (mkIdentPosition p (sval a))

sym :: Parser Token Ident a
sym = (\ pos -> mkIdentPosition pos . sval) <$> position <*>
      tokens [Sym, SymDot, SymMinus, SymMinusDot]

qSym :: Parser Token QualIdent a
qSym = qualify <$> sym <|> mkQIdent <$> position <*> token QSym
  where mkQIdent p a = qualifyWith (mkMIdent (modulVal a))
                                   (mkIdentPosition p (sval a))

colon :: Parser Token QualIdent a
colon = (\ p -> qualify $ addPositionIdent p consId) <$> tokenPos Colon

minus :: Parser Token Ident a
minus = (\ p -> addPositionIdent p minusId) <$> tokenPos SymMinus

fminus :: Parser Token Ident a
fminus = (\ p -> addPositionIdent p fminusId) <$> tokenPos SymMinusDot

tupleCommas :: Parser Token QualIdent a
tupleCommas = (\ p -> qualify . addPositionIdent p . tupleId . succ . length)
              <$> position <*> many1 comma

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

-- |This function starts a new layout block but does not wait for its end.
-- This is only used for parsing the module header.
startLayout :: Parser Token a b -> Parser Token a b
startLayout p = layoutOff <-*> leftBraceSemicolon <-*> p
             <|> layoutOn <-*> p

layout :: Parser Token a b -> Parser Token a b
layout p =  layoutOff <-*> between leftBraceSemicolon p rightBrace
        <|> layoutOn  <-*> p <*-> (token VRightBrace <|> layoutEnd)

-- ---------------------------------------------------------------------------
-- Bracket combinators
-- ---------------------------------------------------------------------------

braces :: Parser Token a b -> Parser Token a b
braces p = between leftBrace p rightBrace

brackets :: Parser Token a b -> Parser Token a b
brackets p = between leftBracket p rightBracket

parens :: Parser Token a b -> Parser Token a b
parens p = between leftParen p rightParen

backquotes :: Parser Token a b -> Parser Token a b
backquotes p = between backquote p expectBackquote

-- ---------------------------------------------------------------------------
-- Simple token parsers
-- ---------------------------------------------------------------------------

token :: Category -> Parser Token Attributes a
token c = attr <$> symbol (Token c NoAttributes)
  where attr (Token _ a) = a

tokens :: [Category] -> Parser Token Attributes a
tokens = foldr1 (<|>) . map token

tokenPos :: Category -> Parser Token Position a
tokenPos c = position <*-> token c

tokenOps :: [(Category, a)] -> Parser Token a b
tokenOps cs = ops [(Token c NoAttributes, x) | (c, x) <- cs]

comma :: Parser Token Attributes a
comma = token Comma

semicolon :: Parser Token Attributes a
semicolon = token Semicolon <|> token VSemicolon

bar :: Parser Token Attributes a
bar = token Bar

equals :: Parser Token Attributes a
equals = token Equals

expectEquals :: Parser Token Attributes a
expectEquals = equals <?> "= expected"

expectWhere :: Parser Token Attributes a
expectWhere = token KW_where <?> "where expected"

expectRightArrow :: Parser Token Attributes a
expectRightArrow  = token RightArrow <?> "-> expected"

backquote :: Parser Token Attributes a
backquote = token Backquote

expectBackquote :: Parser Token Attributes a
expectBackquote = backquote <?> "backquote (`) expected"

leftParen :: Parser Token Attributes a
leftParen = token LeftParen

rightParen :: Parser Token Attributes a
rightParen = token RightParen

leftBracket :: Parser Token Attributes a
leftBracket = token LeftBracket

rightBracket :: Parser Token Attributes a
rightBracket = token RightBracket

leftBrace :: Parser Token Attributes a
leftBrace = token LeftBrace

leftBraceSemicolon :: Parser Token Attributes a
leftBraceSemicolon = token LeftBraceSemicolon

rightBrace :: Parser Token Attributes a
rightBrace = token RightBrace

leftArrow :: Parser Token Attributes a
leftArrow = token LeftArrow

-- ---------------------------------------------------------------------------
-- Ident
-- ---------------------------------------------------------------------------

mkIdentPosition :: Position -> String -> Ident
mkIdentPosition pos = addPositionIdent pos . mkIdent
