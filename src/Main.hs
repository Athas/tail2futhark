module Main where

import System.IO
import System.Exit
import System.Console.GetOpt
import System.Environment
import APLAcc.TAIL.Parser (parseFile)
import Tail2Futhark.Futhark.Pretty (prettyPrint)
import Tail2Futhark.Compile (compile)
import Options

main :: IO ()
main = do
  cmdargs <- getArgs
  let (opts,args,errors) = runArgs cmdargs

  checkErrors errors
  program <- run args
  case outputFile opts of
    Nothing -> putStrLn . prettyPrint . compile opts $ program
    Just  f -> withFile f WriteMode (\h -> hPutStr h $ prettyPrint . compile opts $ program)


checkErrors [] = return ()
checkErrors errors = putStrLn (concat errors ++ usageInfo "Usage: tail2futhark [options] FILE" options) >> exitFailure

-- nonargs list of functions typed : Options -> Options
runArgs :: [String] -> (Options,[String],[String])
runArgs cmdargs = (opts,args,errors)
  where
  (nonargs,args,errors) = getOpt Permute options cmdargs
  opts = foldl (.) id nonargs defaultOptions -- MAGIC!!!! - our ooption record

run [] = putStrLn (usageInfo "Usage: tail2futhark [options] FILE" options) >> exitFailure
run (f : _) = withFile f ReadMode $ flip parseFile f
