{-# LANGUAGE OverloadedStrings #-}
--
-- Core.hs --- Top-level interface to Lobster core.
--
-- Copyright (C) 2014, Galois, Inc.
-- All Rights Reserved.
--
-- Released under the "BSD3" license.  See the file "LICENSE"
-- for details.
--

module Lobster.Core
  ( readPolicy
  , readPolicyBS
  , parseByteString
  , spanErrorMessage

  , module Lobster.Core.Lexer
  , module Lobster.Core.Parser
  , module Lobster.Core.AST
  , module Lobster.Core.Error
  , module Lobster.Core.Eval
  , module Lobster.Core.TypeCheck
  , module Lobster.Core.Traverse
  , module Lobster.Core.JSON
  ) where

import Control.Error (EitherT, hoistEither)
import Control.Monad.IO.Class (liftIO)
import Data.Monoid ((<>))
import Data.Text (Text, pack)

import Lobster.Core.Lexer
import Lobster.Core.Parser
import Lobster.Core.AST
import Lobster.Core.Error
import Lobster.Core.Eval
import Lobster.Core.TypeCheck
import Lobster.Core.Traverse
import Lobster.Core.JSON
import Lobster.Core.Pretty ()

import qualified Data.ByteString.Lazy as LBS

-- | Parse a bytestring and return a policy.
parseByteString :: LBS.ByteString -> Either (Error Span) (Policy Span)
parseByteString s = runAlex s parsePolicy

-- | Parse and evaluate a Lobster file.
readPolicy :: FilePath -> EitherT (Error Span) IO (Module Span)
readPolicy path = do
  contents  <- liftIO $ LBS.readFile path
  hoistEither $ do
    policy <- parseByteString contents
    tc =<< evalPolicy policy

-- | Read a policy from a bytestring.
readPolicyBS :: LBS.ByteString -> Either (Error Span) (Module Span)
readPolicyBS s = do
  policy <- runAlex s parsePolicy
  tc =<< evalPolicy policy

----------------------------------------------------------------------
-- Utilities

-- | Return a string describing a source location for console
-- output.  This only looks at the start location.
spanStartText :: Maybe Span -> Text
spanStartText Nothing = "<unknown>"
spanStartText (Just (Span NoLoc _)) = "<end of file>"
spanStartText (Just (Span (Loc (line, col)) _)) =
  pack (show line) <> ":" <> pack (show col)

-- | Return an error message with source location information.
spanErrorMessage :: Error Span -> Text
spanErrorMessage err = loc <> ": " <> msg
  where
    loc = spanStartText (errorLabel err)
    msg = errorMessage err

