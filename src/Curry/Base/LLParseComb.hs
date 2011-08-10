{- |
    Module      :  $Header$
    Description :  Parser combinators
    Copyright   :  (c) 1999-2004, Wolfgang Lux
    License     :  OtherLicense

    Maintainer  :  bjp@informatik.uni-kiel.de
    Stability   :  experimental
    Portability :  portable

    The parsing combinators implemented in this module
    are based on the LL(1) parsing combinators developed by Swierstra and
    Duponcheel. They have been
    adapted to using continuation passing style in order to work with the
    lexing combinators described in the previous section. In addition, the
    facilities for error correction are omitted in this implementation.

    The two functions 'applyParser' and 'prefixParser' use
    the specified parser for parsing a string. When 'applyParser'
    is used, an error is reported if the parser does not consume the whole
    string, whereas 'prefixParser' discards the rest of the input
    string in this case.
-}
module Curry.Base.LLParseComb
  ( -- * Data types
    Symbol (..), Parser

    -- * Parser application
  , applyParser, prefixParser

    -- * parser combinators
  , position, succeed, symbol, (<?>), (<|>), (<|?>), (<*>), (<\>), (<\\>)
  , opt, (<$>), (<$->), (<*->), (<-*>), (<**>), (<??>), (<.>), many, many1
  , sepBy, sepBy1, chainr, chainr1, chainl, chainl1, bracket, ops

    -- * Layout combinators
  , layoutOn, layoutOff, layoutEnd
  ) where

import Control.Monad
import Data.Maybe
import qualified Data.Set as Set
import qualified Data.Map as Map

import Curry.Base.LexComb
import Curry.Base.MessageMonad
import Curry.Base.Position

infixl 5 <\>, <\\>
infixl 4 <*>, <$>, <$->, <*->, <-*>, <**>, <??>, <.>
infixl 3 <|>, <|?>
infixl 2 <?>, `opt`

-- ---------------------------------------------------------------------------
-- Parser types
-- ---------------------------------------------------------------------------

-- |Type class for symbols
class (Ord s, Show s) => Symbol s where
  isEOF :: s -> Bool

type SuccessCont s a = Position -> s -> P a
type FailureCont a   = Position -> String -> P a
type Lexer s a       = SuccessCont s a -> FailureCont a -> P a
type ParseFun s a b  = (a -> SuccessCont s b) -> FailureCont b
                       -> SuccessCont s b

data Parser s a b = Parser (Maybe (ParseFun s a b))
                           (Map.Map s (Lexer s b -> ParseFun s a b))

instance Symbol s => Show (Parser s a b) where
  showsPrec p (Parser e ps) = showParen (p >= 10) $
    showString "Parser " . shows (isJust e) .
    showChar ' ' . shows (Map.keysSet ps)

-- ---------------------------------------------------------------------------
-- Parser application
-- ---------------------------------------------------------------------------

applyParser :: Symbol s => Parser s a a -> Lexer s a -> FilePath -> String
            -> MsgMonad a
applyParser p lexer = parse (lexer (choose p lexer done failP) failP)
  where done x pos s
          | isEOF s = returnP x
          | otherwise = failP pos (unexpected s)

prefixParser :: Symbol s => Parser s a a -> Lexer s a -> FilePath -> String
             -> MsgMonad a
prefixParser p lexer = parse (lexer (choose p lexer discard failP) failP)
  where discard x _ _ = returnP x

choose :: Symbol s => Parser s a b -> Lexer s b -> ParseFun s a b
choose (Parser e ps) lexer success failp pos s =
  case Map.lookup s ps of
    Just p -> p lexer success failp pos s
    Nothing ->
      case e of
        Just p -> p success failp pos s
        Nothing -> failp pos (unexpected s)

unexpected :: Symbol s => s -> String
unexpected s
  | isEOF s   = "Unexpected end-of-file"
  | otherwise = "Unexpected token " ++ show s

-- ---------------------------------------------------------------------------
-- Basic combinators
-- ---------------------------------------------------------------------------

position :: Symbol s => Parser s Position b
position = Parser (Just p) Map.empty
  where p success _ pos = success pos pos

succeed :: Symbol s => a -> Parser s a b
succeed x = Parser (Just p) Map.empty
  where p success _ = success x

-- |Create a parser accepting the given 'Symbol'
symbol :: Symbol s => s -> Parser s s a
symbol s = Parser Nothing (Map.singleton s p)
  where p lexer success failp _pos s' = lexer (success s') failp

-- |Behave like the given parser, but if it fails to accept the word the
--  error message is used
(<?>) :: Symbol s => Parser s a b -> String -> Parser s a b
p <?> msg = p <|> Parser (Just pfail) Map.empty
  where pfail _ failp pos _ = failp pos msg

-- |
(<|>) :: Symbol s => Parser s a b -> Parser s a b -> Parser s a b
Parser e1 ps1 <|> Parser e2 ps2
  | isJust e1 && isJust e2 = error "Ambiguous parser for empty word"
  | not (Set.null common)  = error $ "Ambiguous parser for " ++ show common
  | otherwise = Parser (e1 `mplus` e2) (Map.union ps1 ps2)
  where common = Map.keysSet ps1 `Set.intersection` Map.keysSet ps2

-- ---------------------------------------------------------------------------
-- The parsing combinators presented so far require that the grammar
-- being parsed is LL(1). In some cases it may be difficult or even
-- impossible to transform a grammar into LL(1) form. As a remedy, we
-- include a non-deterministic version of the choice combinator in
-- addition to the deterministic combinator adapted from the paper. For
-- every symbol from the intersection of the parser's first sets, the
-- combinator \texttt{(<|?>)} applies both parsing functions to the input
-- stream and uses that one which processes the longer prefix of the
-- input stream irrespective of whether it succeeds or fails. If both
-- functions recognize the same prefix, we choose the one that succeeds
-- and report an ambiguous parse error if both succeed.
-- ---------------------------------------------------------------------------

(<|?>) :: Symbol s => Parser s a b -> Parser s a b -> Parser s a b
Parser e1 ps1 <|?> Parser e2 ps2
  | isJust e1 && isJust e2 = error "Ambiguous parser for empty word"
  | otherwise = Parser (e1 `mplus` e2) (Map.union ps1' ps2)
  where ps1' = Map.fromList [(s,maybe p (try p) (Map.lookup s ps2))
                          | (s,p) <- Map.toList ps1]
        try p1 p2 lexer success failp pos s =
          closeP1 p2s `thenP` \p2s' ->
          closeP1 p2f `thenP` \p2f' ->
          parse' p1 (retry p2s') (retry p2f')
          where p2s r1 = parse' p2 (select True r1) (select False r1)
                p2f r1 = parse' p2 (flip (select False) r1) (select False r1)
                parse' p psucc pfail =
                  p lexer (successK psucc) (failK pfail) pos s
                successK k x pos' s' = k (pos', success x pos' s')
                failK k pos' msg = k (pos', failp pos' msg)
                retry k (pos',p) = closeP0 p `thenP` curry k pos'
        select suc (pos1, p1) (pos2, p2) =
          case pos1 `compare` pos2 of
            GT -> p1
            EQ
              | suc -> error ("Ambiguous parse before " ++ show pos1)
              | otherwise -> p1
            LT -> p2

-- |Apply the result function of the first parser to the result of the
--  second parser.
(<*>) :: Symbol s => Parser s (a -> b) c -> Parser s a c -> Parser s b c
Parser (Just p1) ps1 <*> ~p2@(Parser e2 ps2) =
  Parser (fmap (seqEE p1) e2)
         (Map.union (fmap (flip seqPP p2) ps1) (fmap (seqEP p1) ps2))
Parser Nothing ps1 <*> p2 = Parser Nothing (fmap (flip seqPP p2) ps1)

seqEE :: Symbol s => ParseFun s (a -> b) c -> ParseFun s a c
      -> ParseFun s b c
seqEE p1 p2 success failp = p1 (\f -> p2 (success . f) failp) failp

seqEP :: Symbol s => ParseFun s (a -> b) c -> (Lexer s c -> ParseFun s a c)
      -> Lexer s c -> ParseFun s b c
seqEP p1 p2 lexer success failp = p1 (\f -> p2 lexer (success . f) failp) failp

seqPP :: Symbol s => (Lexer s c -> ParseFun s (a -> b) c) -> Parser s a c
      -> Lexer s c -> ParseFun s b c
seqPP p1 p2 lexer success failp =
  p1 lexer (\f -> choose p2 lexer (success . f) failp) failp

-- ---------------------------------------------------------------------------
-- The combinators \verb|<\\>| and \verb|<\>| can be used to restrict
-- the first set of a parser. This is useful for combining two parsers
-- with an overlapping first set with the deterministic combinator <|>.
-- ---------------------------------------------------------------------------

(<\>) :: Symbol s => Parser s a c -> Parser s b c -> Parser s a c
p <\> Parser _ ps = p <\\> Map.keys ps

(<\\>) :: Symbol s => Parser s a b -> [s] -> Parser s a b
Parser e ps <\\> xs = Parser e (foldr Map.delete ps xs)

-- ---------------------------------------------------------------------------
-- Other combinators
-- Note that some of these combinators have not been published in the
-- paper, but were taken from the implementation found on the web.
-- ---------------------------------------------------------------------------

opt :: Symbol s => Parser s a b -> a -> Parser s a b
p `opt` x = p <|> succeed x

-- | Apply a function to the result of a parser.
--   The result is a parser accepting the same language but with its result
--   modified by the given function.
(<$>) :: Symbol s => (a -> b) -> Parser s a c -> Parser s b c
f <$> p = succeed f <*> p

(<$->) :: Symbol s => a -> Parser s b c -> Parser s a c
f <$-> p = const f <$> p

(<*->) :: Symbol s => Parser s a c -> Parser s b c -> Parser s a c
p <*-> q = const <$> p <*> q

(<-*>) :: Symbol s => Parser s a c -> Parser s b c -> Parser s b c
p <-*> q = const id <$> p <*> q

(<**>) :: Symbol s => Parser s a c -> Parser s (a -> b) c -> Parser s b c
p <**> q = flip ($) <$> p <*> q

(<??>) :: Symbol s => Parser s a b -> Parser s (a -> a) b -> Parser s a b
p <??> q = p <**> (q `opt` id)

(<.>) :: Symbol s => Parser s (a -> b) d -> Parser s (b -> c) d
      -> Parser s (a -> c) d
p1 <.> p2 = p1 <**> ((.) <$> p2)

many :: Symbol s => Parser s a b -> Parser s [a] b
many p = many1 p `opt` []

many1 :: Symbol s => Parser s a b -> Parser s [a] b
-- many1 p = (:) <$> p <*> many p
many1 p = (:) <$> p <*> (many1 p `opt` [])

-- The first definition of \texttt{many1} is commented out because it
-- does not compile under nhc. This is due to a -- known -- bug in the
-- type checker of nhc which expects a default declaration when compiling
-- mutually recursive functions with class constraints. However, no such
-- default can be given in the above case because neither of the types
-- involved is a numeric type.

sepBy :: Symbol s => Parser s a c -> Parser s b c -> Parser s [a] c
p `sepBy` q = p `sepBy1` q `opt` []

sepBy1 :: Symbol s => Parser s a c -> Parser s b c -> Parser s [a] c
p `sepBy1` q = (:) <$> p <*> many (q <-*> p)

chainr :: Symbol s => Parser s a b -> Parser s (a -> a -> a) b -> a
       -> Parser s a b
chainr p op x = chainr1 p op `opt` x

chainr1 :: Symbol s => Parser s a b -> Parser s (a -> a -> a) b
        -> Parser s a b
chainr1 p op = r
  where r = p <**> (flip <$> op <*> r `opt` id)

chainl :: Symbol s => Parser s a b -> Parser s (a -> a -> a) b -> a
       -> Parser s a b
chainl p op x = chainl1 p op `opt` x

chainl1 :: Symbol s => Parser s a b -> Parser s (a -> a -> a) b
        -> Parser s a b
chainl1 p op = foldF <$> p <*> many (flip <$> op <*> p)
  where foldF x [] = x
        foldF x (f:fs) = foldF (f x) fs

bracket :: Symbol s => Parser s a c -> Parser s b c -> Parser s a c
        -> Parser s b c
bracket open p close = open <-*> p <*-> close

ops :: Symbol s => [(s,a)] -> Parser s a b
ops [] = error "internal error: ops"
ops [(s,x)] = x <$-> symbol s
ops ((s,x):rest) = x <$-> symbol s <|> ops rest

-- ---------------------------------------------------------------------------
-- Layout combinators
-- Note that the layout functions grab the next token (and its position).
-- After modifying the layout context, the continuation is called with
-- the same token and an undefined result.
-- ---------------------------------------------------------------------------

layoutOn :: Symbol s => Parser s a b
layoutOn = Parser (Just on) Map.empty
  where on success _ pos = pushContext (column pos) . success undefined pos

layoutOff :: Symbol s => Parser s a b
layoutOff = Parser (Just off) Map.empty
  where off success _ pos = pushContext (-1) . success undefined pos

layoutEnd :: Symbol s => Parser s a b
layoutEnd = Parser (Just end) Map.empty
  where end success _ pos = popContext . success undefined pos