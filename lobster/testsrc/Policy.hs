module Policy where

import System.FilePath((<.>))
import System.Directory(getDirectoryContents)
import System.FilePath((</>))

import Prelude hiding (catch)
import Control.Exception (catch, SomeException)
import Control.Error (runEitherT, fmapLT, throwT, hoistEither)
import Data.Either (lefts)

import qualified System.IO
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Maybe as Maybe

import Lobster.Policy ( Domain, Policy )
import Lobster.Error (Error(MiscError))

import qualified Lobster.Lexer as Lex
import qualified Lobster.Parser as Par
import qualified Lobster.Policy as P

import Test.Framework.Providers.HUnit
import Test.Framework.Providers.API ( Test )
import Test.HUnit hiding ( Test )

testCases :: [(Bool, FilePath)] -> [Test]
testCases lobsterPolicies = map buildCase $ zip [1 .. ] lobsterPolicies

buildCase (i, params) = do
  testCase ("Policy test #"++show i) $ checkPolicy params

checkPolicy :: (Bool, FilePath) -> IO ()
checkPolicy (shouldFail, testPolicyFilename) =
    do succeeded <- testPolicy testPolicyFilename
       case succeeded of
         Left e  -> if shouldFail
                     then return ()
                     else do
                       error $ "should have succeeded on " ++ testPolicyFilename ++ "\n"
                             ++ "Output: \n" ++ e
         Right _ -> if shouldFail
                     then error $ "should have failed on " ++ testPolicyFilename
                     else return ()

testappDirectory :: String
testappDirectory = "../SELinux/testapp"

lobsterExamplePoliciesDirectory :: String
lobsterExamplePoliciesDirectory = "test/examples"

testappPolicy :: String
testappPolicy = testappDirectory </> "testapp.lsr"

-- | Retrieves all the tests from the test/examples directory,
-- creating a @(True, <path>)@ entry for all files named
-- @exampleN.lsr@ and a @(False, <path>)@ entry for all files named
-- @errorN.lsr@
getLobsterExamplePolicies :: IO [(Bool,FilePath)]
getLobsterExamplePolicies = do
    fns <- getDirectoryContents lobsterExamplePoliciesDirectory
    return (map rejoin $ List.sort $ Maybe.mapMaybe split fns)
  where
    split :: String -> Maybe (String,Int,String,String)
    split f =
        let (v,f') = List.span Char.isAlpha f in
        let (n,f'') = List.span Char.isDigit f' in
        if f'' == ".lsr" then Just (v, length n, n, f) else Nothing

    rejoin :: (String,Int,String,String) -> (Bool,String)
    rejoin (v,_,_,f) =
        let b = if v == "example" then False
                else if v == "error" then True
                else error $ "bad test file prefix: " ++ v in
        (b, lobsterExamplePoliciesDirectory </> f)

getLobsterPolicies :: IO [(Bool,FilePath)]
getLobsterPolicies = do
    fns <- getLobsterExamplePolicies
    return $ fns ++ [(False,testappPolicy)]


-- | Test a lobster file to see if it will parse, interpret, and
-- flatten.  This is a wrapper around 'checkFile' that catches
-- exceptions and transforms them into @False@ return values.
testPolicy :: FilePath -> IO (Either String ())
testPolicy file = catch (checkFile file) handler
    where handler :: SomeException -> IO (Either String ())
          handler e = return $ Left (show e)

-- | Attempt to parse, interpret, and flatten a lobster source file.
-- Throws exceptions in some failure cases.
--
-- FIXME: clean this up?
checkFile :: FilePath -> IO (Either String ())
checkFile file = runEitherT $ fmapLT show $ do
  policy <- P.parsePolicyFile file
  (es, domain) <- hoistEither $ P.interpretPolicy policy
  case lefts es of
    [] -> case P.flattenDomain domain of
            Left  e -> throwT e
            Right _ -> return ()
    xs  -> throwT $ MiscError (unlines xs)
