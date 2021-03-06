{- |
    Module      :  $Header$
    Description :  Utility functions for Curry's abstract syntax
    Copyright   :  (c) 1999 - 2004 Wolfgang Lux
                       2005        Martin Engelke
                       2011 - 2014 Björn Peemöller
                       2015        Jan Tikovsky
    License     :  BSD-3-clause

    Maintainer  :  bjp@informatik.uni-kiel.de
    Stability   :  experimental
    Portability :  portable

    This module provides some utility functions for working with the
    abstract syntax tree of Curry.
-}

module Curry.Syntax.Utils
  ( hasLanguageExtension, knownExtensions
  , isTypeSig, infixOp, isTypeDecl, isValueDecl, isInfixDecl
  , isFunctionDecl, isExternalDecl, patchModuleId
  , flatLhs, mkInt, fieldLabel, fieldTerm, field2Tuple, opName
  , addSrcRefs
  , constrId, nconstrId
  , recordLabels, nrecordLabels
  ) where

import Control.Monad.State
import Data.Generics

import Curry.Base.Ident
import Curry.Base.Position
import Curry.Files.Filenames (takeBaseName)
import Curry.Syntax.Extension
import Curry.Syntax.Type

-- |Check whether a 'Module' has a specific 'KnownExtension' enabled by a pragma
hasLanguageExtension :: Module -> KnownExtension -> Bool
hasLanguageExtension mdl ext = ext `elem` knownExtensions mdl

-- |Extract all known extensions from a 'Module'
knownExtensions :: Module -> [KnownExtension]
knownExtensions (Module ps _ _ _ _) =
  [ e | LanguagePragma _ exts <- ps, KnownExtension _ e <- exts]

-- |Replace the generic module name @main@ with the module name derived
-- from the 'FilePath' of the module.
patchModuleId :: FilePath -> Module -> Module
patchModuleId fn m@(Module ps mid es is ds)
  | mid == mainMIdent = Module ps (mkMIdent [takeBaseName fn]) es is ds
  | otherwise         = m

-- |Is the declaration an infix declaration?
isInfixDecl :: Decl -> Bool
isInfixDecl (InfixDecl _ _ _ _) = True
isInfixDecl _                   = False

-- |Is the declaration a type declaration?
isTypeDecl :: Decl -> Bool
isTypeDecl (DataDecl    _ _ _ _) = True
isTypeDecl (NewtypeDecl _ _ _ _) = True
isTypeDecl (TypeDecl    _ _ _ _) = True
isTypeDecl _                     = False

-- |Is the declaration a type signature?
isTypeSig :: Decl -> Bool
isTypeSig (TypeSig         _ _ _) = True
isTypeSig (ForeignDecl _ _ _ _ _) = True
isTypeSig _                       = False

-- |Is the declaration a value declaration?
isValueDecl :: Decl -> Bool
isValueDecl (FunctionDecl    _ _ _) = True
isValueDecl (ForeignDecl _ _ _ _ _) = True
isValueDecl (ExternalDecl      _ _) = True
isValueDecl (PatternDecl     _ _ _) = True
isValueDecl (FreeDecl          _ _) = True
isValueDecl _                       = False

-- |Is the declaration a function declaration?
isFunctionDecl :: Decl -> Bool
isFunctionDecl (FunctionDecl _ _ _) = True
isFunctionDecl _                    = False

-- |Is the declaration an external declaration?
isExternalDecl :: Decl -> Bool
isExternalDecl (ForeignDecl _ _ _ _ _) = True
isExternalDecl (ExternalDecl      _ _) = True
isExternalDecl _                       = False

-- |Convert an infix operator into an expression
infixOp :: InfixOp -> Expression
infixOp (InfixOp     op) = Variable op
infixOp (InfixConstr op) = Constructor op

-- |flatten the left-hand-side to the identifier and all constructor terms
flatLhs :: Lhs -> (Ident, [Pattern])
flatLhs lhs = flat lhs []
  where flat (FunLhs    f ts) ts' = (f, ts ++ ts')
        flat (OpLhs t1 op t2) ts' = (op, t1 : t2 : ts')
        flat (ApLhs  lhs' ts) ts' = flat lhs' (ts ++ ts')

-- |Construct an Integer literal
mkInt :: Integer -> Literal
mkInt i = mk (\r -> Int (addPositionIdent (AST r) anonId) i)

-- |Select the label of a field
fieldLabel :: Field a -> QualIdent
fieldLabel (Field _ l _) = l

-- |Select the term of a field
fieldTerm :: Field a -> a
fieldTerm (Field _ _ t) = t

-- |Select the label and term of a field
field2Tuple :: Field a -> (QualIdent, a)
field2Tuple (Field _ l t) = (l, t)

-- |Get the operator name of an infix operator
opName :: InfixOp -> QualIdent
opName (InfixOp    op) = op
opName (InfixConstr c) = c

---------------------------
-- add source references
---------------------------

-- |Monad for adding source references
type M a = a -> State Int a

-- |Add 'SrcRef's to a 'Module'
addSrcRefs :: Module -> Module
addSrcRefs x = evalState (addRefs x) 0
  where
  addRefs :: Data a' => M a'
  addRefs = down  `extM` addRefPos
                  `extM` addRefSrc
                  `extM` addRefIdent
                  `extM` addRefListPat
                  `extM` addRefListExp
    where
    down :: Data a' => M a'
    down = gmapM addRefs

    nextRef :: State Int SrcRef
    nextRef = do
      i <- get
      put $! i+1
      return $ srcRef i

    addRefSrc :: M SrcRef
    addRefSrc _ = nextRef

    addRefPos :: M [SrcRef]
    addRefPos _ = (:[]) `liftM` nextRef

    addRefIdent :: M Ident
    addRefIdent ident = flip addRefId ident `liftM` nextRef

    addRefListPat :: M Pattern
    addRefListPat (ListPattern _ ts) = uncurry ListPattern `liftM` addRefList ts
    addRefListPat ct                 = down ct

    addRefListExp :: M Expression
    addRefListExp (List _ ts) = uncurry List `liftM` addRefList ts
    addRefListExp ct          = down ct

    addRefList :: Data a' => [a'] -> State Int ([SrcRef],[a'])
    addRefList ts = do
      i <- nextRef
      let add t = do t' <- addRefs t; j <- nextRef; return (j, t')
      ists <- sequence (map add ts)
      let (is,ts') = unzip ists
      return (i:is,ts')

-- | Get the identifier of a constructor declaration
constrId :: ConstrDecl -> Ident
constrId (ConstrDecl _ _ c _) = c
constrId (ConOpDecl _ _ _ op _) = op
constrId (RecordDecl _ _ c _) = c

-- | Get the identifier of a newtype constructor declaration
nconstrId :: NewConstrDecl -> Ident
nconstrId (NewConstrDecl _ _ c _) = c
nconstrId (NewRecordDecl _ _ c _) = c

-- | Get record label identifiers of a constructor declaration
recordLabels :: ConstrDecl -> [Ident]
recordLabels (ConstrDecl   _ _ _ _) = []
recordLabels (ConOpDecl _ _ _ _  _) = []
recordLabels (RecordDecl  _ _ _ fs) = [l | FieldDecl _ ls _ <- fs, l <- ls]

-- | Get record label identifier of a newtype constructor declaration
nrecordLabels :: NewConstrDecl -> [Ident]
nrecordLabels (NewConstrDecl _ _ _ _    )  = []
nrecordLabels (NewRecordDecl _ _ _ (l, _)) = [l]
