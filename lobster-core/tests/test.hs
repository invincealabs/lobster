import Test.Tasty
import Test.Tasty.HUnit

import Control.Applicative ((<$>))
import qualified Data.ByteString.Lazy as LBS
import Data.List (isSuffixOf)
import System.Directory (getDirectoryContents)

import Fixtures (exampleDir, getFixture)
import qualified LexTest as LT
import qualified ParseTest as PT
import qualified EvalTest as ET

type Fixtures = [(FilePath, LBS.ByteString)]

main :: IO ()
main = do
  valid   <- validExamples
  invalid <- invalidExamples
  defaultMain (tests valid invalid)

tests :: Fixtures -> Fixtures -> TestTree
tests valid invalid = testGroup "lobster-core"
  [ testEnvTests valid invalid
  , LT.unitTests valid invalid
  , PT.unitTests valid invalid
  , ET.unitTests
  ]

testEnvTests :: Fixtures -> Fixtures -> TestTree
testEnvTests valid invalid = testGroup "test environment tests"
  [ testCase "valid test fixtures are available" $
      length valid >= 1 @? "at least one valid fixture is available"
  , testCase "invalid test fixtures are available" $
      length invalid >= 1 @? "at least one invalid fixture is available"
  ]

lobsterExamples :: IO Fixtures
lobsterExamples = do
  files <- filter (".lsr" `isSuffixOf`) <$> getDirectoryContents exampleDir
  contents <- mapM getFixture files
  return (zip files contents)

validExamples :: IO Fixtures
validExamples =
  filter (\(path, _) -> "example.lsr" `isSuffixOf` noNum path) <$> lobsterExamples

invalidExamples :: IO Fixtures
invalidExamples =
  filter (\(path, _) -> "error.lsr" `isSuffixOf` noNum path) <$> lobsterExamples

noNum :: FilePath -> FilePath
noNum = filter $ not . (`elem` ['0'..'9'])
