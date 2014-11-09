-----------------------------------------------------------------------------
--
-- Module      :  Main
-- Copyright   :  (c) Phil Freeman 2013
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------

{-# LANGUAGE DataKinds, GeneralizedNewtypeDeriving, TupleSections, RecordWildCards #-}

module Main where

import Control.Applicative
import Control.Monad.Error

import Data.Bool (bool)
import Data.Version (showVersion)

import System.Console.CmdTheLine
import System.Directory
       (doesFileExist, getModificationTime, createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import System.Exit (exitSuccess, exitFailure)
import System.IO.Error (tryIOError)

import qualified Language.PureScript as P
import qualified Paths_purescript as Paths
import qualified System.IO.UTF8 as U

data InputOptions = InputOptions
  { ioNoPrelude   :: Bool
  , ioInputFiles  :: [FilePath]
  }

readInput :: InputOptions -> IO [(Either P.RebuildPolicy FilePath, String)]
readInput InputOptions{..} = do
  content <- forM ioInputFiles $ \inputFile -> (Right inputFile, ) <$> U.readFile inputFile
  return $ bool ((Left P.RebuildNever, P.prelude) :) id ioNoPrelude content

newtype Make a = Make { unMake :: ErrorT String IO a } deriving (Functor, Applicative, Monad, MonadIO, MonadError String)

runMake :: Make a -> IO (Either String a)
runMake = runErrorT . unMake

makeIO :: IO a -> Make a
makeIO = Make . ErrorT . fmap (either (Left . show) Right) . tryIOError

instance P.MonadMake Make where
  getTimestamp path = makeIO $ do
    exists <- doesFileExist path
    case exists of
      True -> Just <$> getModificationTime path
      False -> return Nothing
  readTextFile path = makeIO $ do
    U.putStrLn $ "Reading " ++ path
    U.readFile path
  writeTextFile path text = makeIO $ do
    mkdirp path
    U.putStrLn $ "Writing " ++ path
    U.writeFile path text
  liftError = either throwError return
  progress = makeIO . U.putStrLn

compile :: [FilePath] -> FilePath -> P.Options P.Make -> Bool -> IO ()
compile input outputDir opts usePrefix = do
  modules <- P.parseModulesFromFiles (either (const "") id) <$> readInput (InputOptions (P.optionsNoPrelude opts) input)
  case modules of
    Left err -> do
      U.print err
      exitFailure
    Right ms -> do
      e <- runMake $ P.make outputDir opts ms prefix
      case e of
        Left err -> do
          U.putStrLn err
          exitFailure
        Right _ -> do
          exitSuccess
  where
    prefix = if usePrefix
               then ["Generated by psc-make version " ++ showVersion Paths.version]
               else []

mkdirp :: FilePath -> IO ()
mkdirp = createDirectoryIfMissing True . takeDirectory

inputFiles :: Term [FilePath]
inputFiles = value $ posAny [] $ posInfo
     { posDoc = "The input .ps files" }

outputDirectory :: Term FilePath
outputDirectory = value $ opt "output" $ (optInfo [ "o", "output" ])
     { optDoc = "The output directory" }

noTco :: Term Bool
noTco = value $ flag $ (optInfo [ "no-tco" ])
     { optDoc = "Disable tail call optimizations" }

noPrelude :: Term Bool
noPrelude = value $ flag $ (optInfo [ "no-prelude" ])
     { optDoc = "Omit the Prelude" }

noMagicDo :: Term Bool
noMagicDo = value $ flag $ (optInfo [ "no-magic-do" ])
     { optDoc = "Disable the optimization that overloads the do keyword to generate efficient code specifically for the Eff monad." }

noOpts :: Term Bool
noOpts = value $ flag $ (optInfo [ "no-opts" ])
     { optDoc = "Skip the optimization phase." }

verboseErrors :: Term Bool
verboseErrors = value $ flag $ (optInfo [ "v", "verbose-errors" ])
     { optDoc = "Display verbose error messages" }

options :: Term (P.Options P.Make)
options = P.Options <$> noPrelude <*> noTco <*> noMagicDo <*> pure Nothing <*> noOpts <*> verboseErrors <*> pure P.MakeOptions

noPrefix :: Term Bool
noPrefix = value $ flag $ (optInfo ["p", "no-prefix" ])
     { optDoc = "Do not include comment header"}

term :: Term (IO ())
term = compile <$> inputFiles <*> outputDirectory <*> options <*> (not <$> noPrefix)

termInfo :: TermInfo
termInfo = defTI
  { termName = "psc-make"
  , version  = showVersion Paths.version
  , termDoc  = "Compiles PureScript to Javascript"
  }

main :: IO ()
main = run (term, termInfo)

