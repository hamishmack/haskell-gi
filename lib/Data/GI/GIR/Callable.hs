module Data.GI.GIR.Callable
    ( Callable(..)
    , parseCallable
    ) where

import Data.GI.GIR.Arg (Arg(..), parseArg, parseTransfer)
import Data.GI.GIR.BasicTypes (Transfer(..), Type)
import Data.GI.GIR.Parser
import Data.GI.GIR.Type (parseOptionalType)

data Callable = Callable {
        returnType :: Maybe Type,
        returnMayBeNull :: Bool,
        returnTransfer :: Transfer,
        args :: [Arg],
        skipReturn :: Bool,
        callableDeprecated :: Maybe DeprecationInfo
    } deriving (Show, Eq)

parseArgs :: Parser [Arg]
parseArgs = do
  paramSets <- parseChildrenWithLocalName "parameters" parseArgSet
  case paramSets of
    [] -> return []
    (ps:[]) -> return ps
    _ -> parseError $ "Unexpected multiple \"parameters\" tag"
  where parseArgSet = parseChildrenWithLocalName "parameter" parseArg

parseOneReturn :: Parser (Maybe Type, Bool, Transfer, Bool)
parseOneReturn = do
  returnType <- parseOptionalType
  allowNone <- optionalAttr "allow-none" False parseBool
  nullable <- optionalAttr "nullable" False parseBool
  transfer <- parseTransfer
  skip <- optionalAttr "skip" False parseBool
  return (returnType, allowNone || nullable, transfer, skip)

parseReturn :: Parser (Maybe Type, Bool, Transfer, Bool)
parseReturn = do
  returnSets <- parseChildrenWithLocalName "return-value" parseOneReturn
  case returnSets of
    (r:[]) -> return r
    [] -> parseError $ "No return information found"
    _ -> parseError $ "Multiple return values found"

parseCallable :: Parser Callable
parseCallable = do
  args <- parseArgs
  (returnType, mayBeNull, transfer, skip) <- parseReturn
  deprecated <- parseDeprecation
  return $ Callable {
                  returnType = returnType
                , returnMayBeNull = mayBeNull
                , returnTransfer = transfer
                , args = args
                , skipReturn = skip
                , callableDeprecated = deprecated
                }
