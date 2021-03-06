{- |
    Module      :  $Header$
    Description :  A pretty printer for Curry
    Copyright   :  (c) 1999 - 2004 Wolfgang Lux
                       2005        Martin Engelke
                       2011 - 2015 Björn Peemöller
    License     :  BSD-3-clause

    Maintainer  :  bjp@informatik.uni-kiel.de
    Stability   :  experimental
    Portability :  portable

    This module implements a pretty printer for Curry expressions. It was
    derived from the Haskell pretty printer provided in Simon Marlow's
    Haskell parser.
-}
module Curry.Syntax.Pretty
  ( ppModule, ppInterface, ppIDecl, ppDecl, ppIdent, ppPattern, ppFieldPatt
  , ppExpr, ppOp, ppStmt, ppFieldExpr, ppTypeExpr, ppAlt
  ) where

import Curry.Base.Ident
import Curry.Base.Pretty

import Curry.Syntax.Type
import Curry.Syntax.Utils (opName)

-- |Pretty print a module
ppModule :: Module -> Doc
ppModule (Module ps m es is ds) = ppModuleHeader ps m es is $$ ppSepBlock ds

ppModuleHeader :: [ModulePragma] -> ModuleIdent -> Maybe ExportSpec
               -> [ImportDecl] -> Doc
ppModuleHeader ps m es is
  | null is   = header
  | otherwise = header $+$ text "" $+$ (vcat $ map ppImportDecl is)
  where header = (vcat $ map ppModulePragma ps)
                 $+$ text "module" <+> ppMIdent m
                 <+> maybePP ppExportSpec es <+> text "where"

ppModulePragma :: ModulePragma -> Doc
ppModulePragma (LanguagePragma _      exts) = text "{-# LANGUAGE"
  <+> list (map ppExtension exts) <+> text "#-}"
ppModulePragma (OptionsPragma  _ tool args) = text "{-# OPTIONS"
  <> maybe empty ((text "_" <>) . ppTool) tool <+> text args <+> text "#-}"

ppExtension :: Extension -> Doc
ppExtension (KnownExtension   _ e) = text (show e)
ppExtension (UnknownExtension _ e) = text e

ppTool :: Tool -> Doc
ppTool (UnknownTool t) = text t
ppTool t               = text (show t)

ppExportSpec :: ExportSpec -> Doc
ppExportSpec (Exporting _ es) = parenList (map ppExport es)

ppExport :: Export -> Doc
ppExport (Export             x) = ppQIdent x
ppExport (ExportTypeWith tc cs) = ppQIdent tc <> parenList (map ppIdent cs)
ppExport (ExportTypeAll     tc) = ppQIdent tc <> text "(..)"
ppExport (ExportModule       m) = text "module" <+> ppMIdent m

ppImportDecl :: ImportDecl -> Doc
ppImportDecl (ImportDecl _ m q asM is) =
  text "import" <+> ppQualified q <+> ppMIdent m <+> maybePP ppAs asM
                <+> maybePP ppImportSpec is
  where ppQualified q' = if q' then text "qualified" else empty
        ppAs m' = text "as" <+> ppMIdent m'

ppImportSpec :: ImportSpec -> Doc
ppImportSpec (Importing _ is) = parenList (map ppImport is)
ppImportSpec (Hiding    _ is) = text "hiding" <+> parenList (map ppImport is)

ppImport :: Import -> Doc
ppImport (Import             x) = ppIdent x
ppImport (ImportTypeWith tc cs) = ppIdent tc <> parenList (map ppIdent cs)
ppImport (ImportTypeAll     tc) = ppIdent tc <> text "(..)"

ppBlock :: [Decl] -> Doc
ppBlock = vcat . map ppDecl

ppSepBlock :: [Decl] -> Doc
ppSepBlock = vcat . map (\d -> text "" $+$ ppDecl d)

-- |Pretty print a declaration
ppDecl :: Decl -> Doc
ppDecl (InfixDecl _ fix p ops) = ppPrec fix p <+> list (map ppInfixOp ops)
ppDecl (DataDecl  _ tc tvs cs) =
  sep (ppTypeDeclLhs "data" tc tvs :
       map indent (zipWith (<+>) (equals : repeat vbar) (map ppConstr cs)))
ppDecl (NewtypeDecl _ tc tvs nc) =
  sep [ppTypeDeclLhs "newtype" tc tvs <+> equals,indent (ppNewConstr nc)]
ppDecl (TypeDecl _ tc tvs ty) =
  sep [ppTypeDeclLhs "type" tc tvs <+> equals,indent (ppTypeExpr 0 ty)]
ppDecl (TypeSig _ fs ty) =
  list (map ppIdent fs) <+> text "::" <+> ppTypeExpr 0 ty
ppDecl (FunctionDecl _ _ eqs) = vcat (map ppEquation eqs)
ppDecl (ForeignDecl p cc impent f ty) =
  sep [text "foreign" <+> ppCallConv cc <+> maybePP (text . show) impent,
       indent (ppDecl (TypeSig p [f] ty))]
  where ppCallConv CallConvPrimitive = text "primitive"
        ppCallConv CallConvCCall     = text "ccall"
ppDecl (ExternalDecl   _ fs) = list (map ppIdent fs) <+> text "external"
ppDecl (PatternDecl _ t rhs) = ppRule (ppPattern 0 t) equals rhs
ppDecl (FreeDecl       _ vs) = list (map ppIdent vs) <+> text "free"

ppPrec :: Infix -> Maybe Precedence -> Doc
ppPrec fix p = pPrint fix <+> ppPrio p
  where
    ppPrio Nothing   = empty
    ppPrio (Just p') = integer p'

ppTypeDeclLhs :: String -> Ident -> [Ident] -> Doc
ppTypeDeclLhs kw tc tvs = text kw <+> ppIdent tc <+> hsep (map ppIdent tvs)

ppConstr :: ConstrDecl -> Doc
ppConstr (ConstrDecl     _ tvs c tys) =
  sep [ppExistVars tvs, ppIdent c <+> fsep (map (ppTypeExpr 2) tys)]
ppConstr (ConOpDecl _ tvs ty1 op ty2) =
  sep [ppExistVars tvs, ppTypeExpr 1 ty1, ppInfixOp op <+> ppTypeExpr 1 ty2]
ppConstr (RecordDecl _ tvs c fs) =
  sep [ppExistVars tvs, ppIdent c <+> record (list (map ppFieldDecl fs))]

ppFieldDecl :: FieldDecl -> Doc
ppFieldDecl (FieldDecl _ ls ty) = list (map ppIdent ls)
                               <+> text "::" <+> ppTypeExpr 0 ty

ppNewConstr :: NewConstrDecl -> Doc
ppNewConstr (NewConstrDecl _ tvs c ty) =
  sep [ppExistVars tvs,ppIdent c <+> ppTypeExpr 2 ty]
ppNewConstr (NewRecordDecl _ tvs c (i,ty)) = sep
  [ ppExistVars tvs
  , ppIdent c <+> record (ppIdent i <+> text "::" <+> ppTypeExpr 0 ty)
  ]

ppExistVars :: [Ident] -> Doc
ppExistVars tvs
  | null tvs = empty
  | otherwise = text "forall" <+> hsep (map ppIdent tvs) <+> char '.'

ppEquation :: Equation -> Doc
ppEquation (Equation _ lhs rhs) = ppRule (ppLhs lhs) equals rhs

ppLhs :: Lhs -> Doc
ppLhs (FunLhs   f ts) = ppIdent f <+> fsep (map (ppPattern 2) ts)
ppLhs (OpLhs t1 f t2) = ppPattern 1 t1 <+> ppInfixOp f <+> ppPattern 1 t2
ppLhs (ApLhs  lhs ts) = parens (ppLhs lhs) <+> fsep (map (ppPattern 2) ts)

ppRule :: Doc -> Doc -> Rhs -> Doc
ppRule lhs eq (SimpleRhs _ e ds) =
  sep [lhs <+> eq, indent (ppExpr 0 e)] $$ ppLocalDefs ds
ppRule lhs eq (GuardedRhs es ds) =
  sep [lhs, indent (vcat (map (ppCondExpr eq) es))] $$ ppLocalDefs ds

ppLocalDefs :: [Decl] -> Doc
ppLocalDefs ds
  | null ds   = empty
  | otherwise = indent (text "where" <+> ppBlock ds)

-- ---------------------------------------------------------------------------
-- Interfaces
-- ---------------------------------------------------------------------------

-- |Pretty print an interface
ppInterface :: Interface -> Doc
ppInterface (Interface m is ds)
  =  text "interface" <+> ppMIdent m <+> text "where" <+> lbrace
  $$ vcat (punctuate semi $ map ppIImportDecl is ++ map ppIDecl ds)
  $$ rbrace

ppIImportDecl :: IImportDecl -> Doc
ppIImportDecl (IImportDecl _ m) = text "import" <+> ppMIdent m

-- |Pretty print an interface declaration
ppIDecl :: IDecl -> Doc
ppIDecl (IInfixDecl   _ fix p op) = ppPrec fix (Just p) <+> ppQInfixOp op
ppIDecl (HidingDataDecl _ tc tvs) =
  text "hiding" <+> ppITypeDeclLhs "data" tc tvs
ppIDecl (IDataDecl   _ tc tvs cs hs) =
  sep (ppITypeDeclLhs "data" tc tvs :
       map indent (zipWith (<+>) (equals : repeat vbar) (map ppConstr cs)) ++
       [indent (ppHiding hs)])
ppIDecl (INewtypeDecl _ tc tvs nc hs) =
  sep [ ppITypeDeclLhs "newtype" tc tvs <+> equals
      , indent (ppNewConstr nc)
      , indent (ppHiding hs)
      ]
ppIDecl (ITypeDecl _ tc tvs ty) =
  sep [ppITypeDeclLhs "type" tc tvs <+> equals,indent (ppTypeExpr 0 ty)]
ppIDecl (IFunctionDecl _ f a ty) = ppQIdent f <+> int a
                               <+> text "::" <+> ppTypeExpr 0 ty

ppITypeDeclLhs :: String -> QualIdent -> [Ident] -> Doc
ppITypeDeclLhs kw tc tvs = text kw <+> ppQIdent tc <+> hsep (map ppIdent tvs)

ppHiding :: [Ident] -> Doc
ppHiding hs
  | null hs   = empty
  | otherwise = text "{-# HIDING" <+> list (map ppIdent hs) <+> text "#-}"

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- |Pretty print a type expression
ppTypeExpr :: Int -> TypeExpr -> Doc
ppTypeExpr p (ConstructorType tc tys) = parenIf (p > 1 && not (null tys))
  (ppQIdent tc <+> fsep (map (ppTypeExpr 2) tys))
ppTypeExpr _ (VariableType   tv) = ppIdent tv
ppTypeExpr _ (TupleType     tys) = parenList (map (ppTypeExpr 0) tys)
ppTypeExpr _ (ListType       ty) = brackets (ppTypeExpr 0 ty)
ppTypeExpr p (ArrowType ty1 ty2) = parenIf (p > 0)
  (fsep (ppArrowType (ArrowType ty1 ty2)))
  where
  ppArrowType (ArrowType ty1' ty2') = ppTypeExpr 1 ty1' <+> rarrow : ppArrowType ty2'
  ppArrowType ty                    = [ppTypeExpr 0 ty]
ppTypeExpr _ (ParenType      ty) = parens (ppTypeExpr 0 ty)

-- ---------------------------------------------------------------------------
-- Literals
-- ---------------------------------------------------------------------------

ppLiteral :: Literal -> Doc
ppLiteral (Char   _ c) = text (show c)
ppLiteral (Int    _ i) = integer i
ppLiteral (Float  _ f) = double f
ppLiteral (String _ s) = text (show s)

-- ---------------------------------------------------------------------------
-- Patterns
-- ---------------------------------------------------------------------------

-- |Pretty print a constructor term
ppPattern :: Int -> Pattern -> Doc
ppPattern p (LiteralPattern l) = parenIf (p > 1 && isNegative l) (ppLiteral l)
  where isNegative (Char   _ _) = False
        isNegative (Int    _ i) = i < 0
        isNegative (Float  _ f) = f < 0.0
        isNegative (String _ _) = False
ppPattern p (NegativePattern    op l) = parenIf (p > 1)
  (ppInfixOp op <> ppLiteral l)
ppPattern _ (VariablePattern       v) = ppIdent v
ppPattern p (ConstructorPattern c ts) = parenIf (p > 1 && not (null ts))
  (ppQIdent c <+> fsep (map (ppPattern 2) ts))
ppPattern p (InfixPattern    t1 c t2) = parenIf (p > 0)
  (sep [ppPattern 1 t1 <+> ppQInfixOp c, indent (ppPattern 0 t2)])
ppPattern _ (ParenPattern          t) = parens (ppPattern 0 t)
ppPattern _ (TuplePattern       _ ts) = parenList (map (ppPattern 0) ts)
ppPattern _ (ListPattern        _ ts) = bracketList (map (ppPattern 0) ts)
ppPattern _ (AsPattern           v t) = ppIdent v <> char '@' <> ppPattern 2 t
ppPattern _ (LazyPattern         _ t) = char '~' <> ppPattern 2 t
ppPattern p (FunctionPattern    f ts) = parenIf (p > 1 && not (null ts))
  (ppQIdent f <+> fsep (map (ppPattern 2) ts))
ppPattern p (InfixFuncPattern t1 f t2) = parenIf (p > 0)
  (sep [ppPattern 1 t1 <+> ppQInfixOp f, indent (ppPattern 0 t2)])
ppPattern p (RecordPattern c fs) = parenIf (p > 1)
  (ppQIdent c <+> record (list (map ppFieldPatt fs)))

-- |Pretty print a record field pattern
ppFieldPatt :: Field Pattern -> Doc
ppFieldPatt (Field _ l t) = ppQIdent l <+> equals <+> ppPattern 0 t

-- ---------------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------------

ppCondExpr :: Doc -> CondExpr -> Doc
ppCondExpr eq (CondExpr _ g e) =
  vbar <+> sep [ppExpr 0 g <+> eq,indent (ppExpr 0 e)]

-- |Pretty print an expression
ppExpr :: Int -> Expression -> Doc
ppExpr _ (Literal        l) = ppLiteral l
ppExpr _ (Variable       v) = ppQIdent v
ppExpr _ (Constructor    c) = ppQIdent c
ppExpr _ (Paren          e) = parens (ppExpr 0 e)
ppExpr p (Typed       e ty) =
  parenIf (p > 0) (ppExpr 0 e <+> text "::" <+> ppTypeExpr 0 ty)
ppExpr _ (Tuple       _ es) = parenList (map (ppExpr 0) es)
ppExpr _ (List        _ es) = bracketList (map (ppExpr 0) es)
ppExpr _ (ListCompr _ e qs) =
  brackets (ppExpr 0 e <+> vbar <+> list (map ppStmt qs))
ppExpr _ (EnumFrom              e) = brackets (ppExpr 0 e <+> text "..")
ppExpr _ (EnumFromThen      e1 e2) =
  brackets (ppExpr 0 e1 <> comma <+> ppExpr 0 e2 <+> text "..")
ppExpr _ (EnumFromTo        e1 e2) =
  brackets (ppExpr 0 e1 <+> text ".." <+> ppExpr 0 e2)
ppExpr _ (EnumFromThenTo e1 e2 e3) =
  brackets (ppExpr 0 e1 <> comma <+> ppExpr 0 e2
              <+> text ".." <+> ppExpr 0 e3)
ppExpr p (UnaryMinus       op e) = parenIf (p > 1) (ppInfixOp op <> ppExpr 1 e)
ppExpr p (Apply           e1 e2) =
  parenIf (p > 1) (sep [ppExpr 1 e1,indent (ppExpr 2 e2)])
ppExpr p (InfixApply   e1 op e2) =
  parenIf (p > 0) (sep [ppExpr 1 e1 <+> ppQInfixOp (opName op),
                         indent (ppExpr 1 e2)])
ppExpr _ (LeftSection      e op) = parens (ppExpr 1 e <+> ppQInfixOp (opName op))
ppExpr _ (RightSection     op e) = parens (ppQInfixOp (opName op) <+> ppExpr 1 e)
ppExpr p (Lambda          _ t e) = parenIf (p > 0)
  (sep [backsl <> fsep (map (ppPattern 2) t) <+> rarrow, indent (ppExpr 0 e)])
ppExpr p (Let              ds e) = parenIf (p > 0)
          (sep [text "let" <+> ppBlock ds, text "in" <+> ppExpr 0 e])
ppExpr p (Do              sts e) = parenIf (p > 0)
          (text "do" <+> (vcat (map ppStmt sts) $$ ppExpr 0 e))
ppExpr p (IfThenElse _ e1 e2 e3) = parenIf (p > 0)
           (text "if" <+>
            sep [ppExpr 0 e1,
                 text "then" <+> ppExpr 0 e2,
                 text "else" <+> ppExpr 0 e3])
ppExpr p (Case    _ ct e alts) = parenIf (p > 0)
           (ppCaseType ct <+> ppExpr 0 e <+> text "of" $$
            indent (vcat (map ppAlt alts)))
ppExpr p (Record c fs) = parenIf (p > 0)
  (ppQIdent c <+> record (list (map ppFieldExpr fs)))
ppExpr _ (RecordUpdate e fs) =
  ppExpr 0 e <+> record (list (map ppFieldExpr fs))

-- |Pretty print a statement
ppStmt :: Statement -> Doc
ppStmt (StmtExpr   _ e) = ppExpr 0 e
ppStmt (StmtBind _ t e) = sep [ppPattern 0 t <+> larrow,indent (ppExpr 0 e)]
ppStmt (StmtDecl    ds) = text "let" <+> ppBlock ds

ppCaseType :: CaseType -> Doc
ppCaseType Rigid = text "case"
ppCaseType Flex  = text "fcase"

-- |Pretty print an alternative in a case expression
ppAlt :: Alt -> Doc
ppAlt (Alt _ t rhs) = ppRule (ppPattern 0 t) rarrow rhs

-- |Pretty print a record field expression (Haskell syntax)
ppFieldExpr :: Field Expression -> Doc
ppFieldExpr (Field _ l e) = ppQIdent l <+> equals <+> ppExpr 0 e

-- |Pretty print an operator
ppOp :: InfixOp -> Doc
ppOp (InfixOp     op) = ppQInfixOp op
ppOp (InfixConstr op) = ppQInfixOp op

-- ---------------------------------------------------------------------------
-- Names
-- ---------------------------------------------------------------------------

-- |Pretty print an identifier
ppIdent :: Ident -> Doc
ppIdent x = parenIf (isInfixOp x) (text (idName x))

ppQIdent :: QualIdent -> Doc
ppQIdent x = parenIf (isQInfixOp x) (text (qualName x))

ppInfixOp :: Ident -> Doc
ppInfixOp x = bquotesIf (not (isInfixOp x)) (text (idName x))

ppQInfixOp :: QualIdent -> Doc
ppQInfixOp x = bquotesIf (not (isQInfixOp x)) (text (qualName x))

ppMIdent :: ModuleIdent -> Doc
ppMIdent m = text (moduleName m)

-- ---------------------------------------------------------------------------
-- Print printing utilities
-- ---------------------------------------------------------------------------

indent :: Doc -> Doc
indent = nest 2

parenList :: [Doc] -> Doc
parenList = parens . list

record :: Doc -> Doc
record doc | isEmpty doc = braces empty
           | otherwise   = braces $ space <> doc <> space

bracketList :: [Doc] -> Doc
bracketList = brackets . list
