{-# Language LambdaCase, ViewPatterns, TemplateHaskell, DeriveFunctor #-}

module Unison.Lexer where

import           Control.Lens.TH (makePrisms)
import           Data.Char
import           Data.Set (Set)
import qualified Data.Set as Set

data Err
  = InvalidWordyId String
  | InvalidSymbolyId String
  | MissingFractional String -- ex `1.` rather than `1.04`
  | UnknownLexeme
  | TextLiteralMissingClosingQuote String
  deriving (Eq,Ord,Show) -- richer algebra

-- Design principle:
--   `[Lexeme]` should be sufficient information for parsing without
--   further knowledge of spacing or indentation levels
--   any knowledge of comments
data Lexeme
  = Open String      -- start of a block
  | Semi             -- separator between elements of a block
  | Close            -- end of a block
  | Reserved String  -- reserved tokens such as `{`, `(`, `type`, `of`, etc
  | Textual String   -- text literals, `"foo bar"`
  | Backticks String -- an identifier in backticks
  | WordyId String   -- a (non-infix) identifier
  | SymbolyId String -- an infix identifier
  | Numeric String   -- numeric literals, left unparsed
  | Err Err
  deriving (Eq,Show,Ord)

makePrisms ''Lexeme

data Token a = Token {
  payload :: a,
  start :: Pos,
  end :: Pos
} deriving (Eq, Ord, Show, Functor)

instance Applicative Token where
  pure a = Token a (Pos 0 0) (Pos 0 0)
  Token f start _ <*> Token a _ end = Token (f a) start end

type Line = Int
type Column = Int

data Pos = Pos {-# Unpack #-} !Line !Column deriving (Eq,Ord,Show)

line :: Pos -> Line
line (Pos line _) = line

column :: Pos -> Column
column (Pos _ column) = column

type Layout = [Column]

top :: Layout -> Column
top []    = 1
top (h:_) = h

pop :: [a] -> [a]
pop = drop 1

topLeftCorner :: Pos
topLeftCorner = Pos 1 1

lexer :: String -> String -> [Token Lexeme]
lexer scope rem =
    Token (Open scope) topLeftCorner topLeftCorner
      : pushLayout [] topLeftCorner rem
  where
    -- skip whitespace and comments
    go1 l pos rem = span' isSpace rem $ \case
      (spaces, '-':'-':rem) -> spanThru' (/= '\n') rem $ \(ignored, rem) ->
        go1 l (incBy ('-':'-':ignored) . incBy spaces $ pos) rem
      (spaces, rem) -> popLayout l (incBy spaces pos) rem

    -- pop the layout stack and emit `Semi` / `Close` tokens as needed
    popLayout l p [] = replicate (length l) $ Token Close p p
    popLayout l p@(Pos _ c2) rem
      | top l == c2 = Token Semi p p : go2 l p rem
      | top l <  c2 = go2 l p rem
      | top l >  c2 = Token Close p p : popLayout (pop l) p rem
      | otherwise   = error "impossible"

    -- todo: is there a reason we want this to be more than just:
    -- go1 (top l + 1 : l) pos rem
    pushLayout l pos rem = span' isSpace rem $ \case
      (spaces, '-':'-':rem) -> spanThru' (/= '\n') rem $ \(ignored, rem) ->
        pushLayout l (incBy ('-':'-':ignored) . incBy spaces $ pos) rem
      (spaces, rem) ->
        let pos' = incBy spaces pos in go2 (column pos' : l) pos' rem

    -- after we've dealt with whitespace and layout, read a token
    go2 l pos rem = case rem of
      -- delimiters - `:`, `@`, `|`, `=`, and `->`
      ch : rem | Set.member ch delimiters ->
        Token (Reserved [ch]) pos (inc pos) : go1 l (inc pos) rem
      ':' : c : rem | isSpace c || isAlphaNum c ->
        Token (Open ":") pos (inc pos) : go1 (top l + 1 : l) (inc pos) (c:rem)
      '@' : rem ->
        Token (Reserved "@") pos (inc pos) : go1 l (inc pos) rem
      '_' : rem | hasSep rem ->
        Token (Reserved "_") pos (inc pos) : go1 l (inc pos) rem
      '|' : c : rem | isSpace c || isAlphaNum c ->
        Token (Reserved "|") pos (inc pos) : go1 l (inc pos) (c:rem)
      '=' : c : rem | isSpace c || isAlphaNum c ->
        Token (Open "=") pos (inc pos) : pushLayout l (inc pos) (c:rem)
      '-' : '>' : (rem @ (c : _))
        | isSpace c || isAlphaNum c || Set.member c delimiters ->
          let end = incBy "->" pos in Token (Reserved "->") pos end : go1 l end rem
          -- (Open "->", pos) : pushLayout l (inc . inc $ pos) rem

      -- string literals and backticked identifiers
      '"' : rem -> span' (/= '"') rem $ \(lit, rem) ->
        if rem == [] then
          [Token (Err (TextLiteralMissingClosingQuote lit)) pos pos]
        else let end = inc . incBy lit . inc $ pos in
                   Token (Textual lit) pos end : go1 l end (pop rem)
      '`' : rem -> case wordyId rem of
        Left e -> Token (Err e) pos pos : recover l pos rem
        Right (id, rem) ->
          let end = inc . incBy id . inc $ pos in
                Token (Backticks id) pos end : go1 l end (pop rem)

      -- keywords and identifiers
      (wordyId -> Right (id, rem)) ->
        let end = incBy id pos in Token (WordyId id) pos end : go1 l end rem
      (symbolyId -> Right (id, rem)) ->
        let end = incBy id pos in Token (SymbolyId id) pos end : go1 l end rem
      (matchKeyword -> Just (kw,rem)) ->
        let end = incBy kw pos in
              case kw of
                kw | Set.member kw layoutKeywords ->
                       Token (Open kw) pos end : pushLayout l end rem
                   | Set.member kw layoutEndKeywords ->
                       Token Close pos pos
                         : Token (Open kw) pos end
                         : pushLayout l end rem
                   | otherwise -> Token (Reserved kw) pos end : go1 l end rem

      -- numeric literals
      rem -> case numericLit rem of
        Right (Just (num, rem)) ->
          let end = incBy num pos in Token (Numeric num) pos end : go1 l end rem
        Right Nothing -> Token (Err UnknownLexeme) pos pos : recover l pos rem
        Left e -> Token (Err e) pos pos : recover l pos rem

    recover _l _pos _rem = []

matchKeyword :: String -> Maybe (String,String)
matchKeyword s = case span (not . isSpace) s of
  (kw, rem) | Set.member kw keywords -> Just (kw, rem)
  _ -> Nothing

numericLit :: String -> Either Err (Maybe (String,String))
numericLit s = go s
  where
  go ('+':s) = go2 "+" s
  go ('-':s) = go2 "-" s
  go s = go2 "" s
  go2 sign s = case span isDigit s of
    (num @ (_:_), []) -> pure $ pure (sign ++ num, [])
    (num @ (_:_), '.':rem) -> case span isDigit rem of
      (fractional @ (_:_), []) ->
        pure $ pure (sign ++ num ++ "." ++ fractional, [])
      (fractional @ (_:_), c:rem)
        | isSep c -> pure $ pure (sign ++ num ++ "." ++ fractional, c:rem)
        | otherwise -> pure Nothing
      ([], _) -> Left (MissingFractional (sign ++ num ++ "."))
    (num @ (_:_), c:rem) | isSep c   -> pure $ pure (sign ++ num, c:rem)
                         | otherwise -> pure Nothing
    ([], _) -> pure Nothing

isSep :: Char -> Bool
isSep c = isSpace c || Set.member c delimiters

hasSep :: String -> Bool
hasSep [] = True
hasSep (ch:_) = isSep ch

-- Not a keyword, has at least one letter, and with all characters matching `wordyIdChar`
wordyId :: String -> Either Err (String, String)
wordyId s = span' wordyIdChar s $ \case
  (id @ (_:_), rem) | not (Set.member id keywords)
                   && any isAlpha id || any isEmoji id -> Right (id, rem)
  (id, _rem) -> Left (InvalidWordyId id)

wordyIdChar :: Char -> Bool
wordyIdChar ch =
  not (isSpace ch) && not (Set.member ch delimiters) && not (Set.member ch reserved)

isEmoji :: Char -> Bool
isEmoji c = c >= '\x1F600' && c <= '\x1F64F'

symbolyId :: String -> Either Err (String, String)
symbolyId s = span' symbolyIdChar s $ \case
  (id @ (_:_), rem) | not (Set.member id reservedOperators) && hasSep rem -> Right (id, rem)
  (id, _rem) -> Left (InvalidSymbolyId id)

symbolyIdChar :: Char -> Bool
symbolyIdChar ch = Set.member ch symbolyIdChars

symbolyIdChars :: Set Char
symbolyIdChars = Set.fromList "!$%^&*-=+<>?.~\\/|"

keywords :: Set String
keywords = Set.fromList [
  "if", "then", "else", "forall", "∀",
  "handle", "in",
  "where",
  "and", "or", "true", "false",
  "type", "effect", "alias",
  "let", "namespace", "case", "of"]

-- These keywords introduce a layout block
layoutKeywords :: Set String
layoutKeywords =
  Set.fromList [
    "if", "then", "else", "in", "let", "where", "of", "namespace"
  ]

-- These keywords end a layout block and begin another layout block
layoutEndKeywords :: Set String
layoutEndKeywords = Set.fromList ["then", "else"]

delimiters :: Set Char
delimiters = Set.fromList "()[]{},"

reserved :: Set Char
reserved = Set.fromList "=:`\""

reservedOperators :: Set String
reservedOperators = Set.fromList ["->"]

inc :: Pos -> Pos
inc (Pos line col) = Pos line (col + 1)

incBy :: String -> Pos -> Pos
incBy rem pos@(Pos line col) = case rem of
  []       -> pos
  '\r':rem -> incBy rem $ Pos line col
  '\n':rem -> incBy rem $ Pos (line + 1) 1
  _:rem    -> incBy rem $ Pos line (col + 1)

ex :: String
ex =
  unlines
  [ "hello -- ignored"
  , "goodbye"
  ]

span' :: (a -> Bool) -> [a] -> (([a],[a]) -> r) -> r
span' f a k = k (span f a)

spanThru' :: (a -> Bool) -> [a] -> (([a],[a]) -> r) -> r
spanThru' f a k = case span f a of
  (l, []) -> k (l, [])
  (l, lz:r) -> k (l ++ [lz], r)

