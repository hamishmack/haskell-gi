-- | Convenience hooks for writing custom @Setup.hs@ files for
-- bindings.
module Data.GI.CodeGen.CabalHooks
    ( setupHaskellGIBinding
    ) where

import qualified Distribution.ModuleName as MN
import Distribution.Simple.LocalBuildInfo
import Distribution.Simple.Setup
import Distribution.Simple (UserHooks(..), simpleUserHooks,
                            defaultMainWithHooks, OptimisationLevel(..),
                            Dependency(..), PackageName(..))
import Distribution.PackageDescription

import Data.GI.CodeGen.API (loadGIRInfo)
import Data.GI.CodeGen.Code (genCode, writeModuleTree, listModuleTree)
import Data.GI.CodeGen.CodeGen (genModule)
import Data.GI.CodeGen.Config (Config(..))
import Data.GI.CodeGen.Overrides (parseOverridesFile, girFixups,
                                  filterAPIsAndDeps)
import Data.GI.CodeGen.PkgConfig (tryPkgConfig)
import Data.GI.CodeGen.Util (ucFirst, tshow)

import Control.Monad (when)

import Data.Maybe (fromJust, fromMaybe)
import qualified Data.Map as M
import Data.Monoid ((<>))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

import System.Directory (doesFileExist)
import System.FilePath ((</>), (<.>))

type ConfHook = (GenericPackageDescription, HookedBuildInfo) -> ConfigFlags
              -> IO LocalBuildInfo

-- | Generate the @PkgInfo@ module, listing the build information for
-- the module. We include in particular the versions for the
-- `pkg-config` dependencies of the module.
genPkgInfo :: [Dependency] -> FilePath -> Text -> IO ()
genPkgInfo deps fName modName = do
  versions <- mapM findVersion deps
  TIO.writeFile fName $ T.unlines
         [ "module " <> modName <> " (pkgConfigVersions) where"
         , ""
         , "import Prelude (String)"
         , ""
         , "pkgConfigVersions :: [(String, String)]"
         , "pkgConfigVersions = " <> tshow versions
         ]
    where findVersion :: Dependency -> IO (Text, Text)
          findVersion (Dependency (PackageName n) _) =
              tryPkgConfig (T.pack n) >>= \case
                  Just v -> return v
                  Nothing -> error ("Could not determine version for required pkg-config module \"" <> n <> "\".")

-- | A convenience helper for `confHook`, such that bindings for the
-- given module are generated in the @configure@ step of @cabal@.
confCodeGenHook :: Text -- ^ name
                -> Text -- ^ version
                -> Bool -- ^ verbose
                -> Maybe FilePath -- ^ overrides file
                -> Maybe FilePath -- ^ output dir
                -> ConfHook -- ^ previous `confHook`
                -> ConfHook
confCodeGenHook name version verbosity overrides outputDir
                defaultConfHook (gpd, hbi) flags = do
  ovsData <- case overrides of
               Nothing -> return ""
               Just fname -> TIO.readFile fname
  ovs <- parseOverridesFile (T.lines ovsData) >>= \case
         Left err -> error $ "Error when parsing overrides file: "
                     ++ T.unpack err
         Right ovs -> return ovs

  (gir, girDeps) <- loadGIRInfo verbosity name (Just version) [] (girFixups ovs)
  let (apis, deps) = filterAPIsAndDeps ovs gir girDeps
      allAPIs = M.union apis deps
      cfg = Config {modName = Just name,
                    verbose = verbosity,
                    overrides = ovs}

  m <- genCode cfg allAPIs ["GI", ucFirst name] (genModule apis)
  alreadyDone <- doesFileExist (fromMaybe "" outputDir
                                </> "GI" </> T.unpack (ucFirst name) <.> "hs")
  moduleList <- if not alreadyDone
                then writeModuleTree verbosity outputDir m
                else return (listModuleTree m)

  let pkgInfoMod = "GI." <> ucFirst name <> ".PkgInfo"
      em' = map (MN.fromString . T.unpack) (pkgInfoMod : moduleList)
      ctd' = ((condTreeData . fromJust . condLibrary) gpd) {exposedModules = em'}
      cL' = ((fromJust . condLibrary) gpd) {condTreeData = ctd'}
      gpd' = gpd {condLibrary = Just cL'}

  when (not alreadyDone) $
       genPkgInfo ((pkgconfigDepends . libBuildInfo . condTreeData .
                    fromJust . condLibrary) gpd)
                  (fromMaybe "" outputDir
                   </> "GI" </> T.unpack (ucFirst name) </> "PkgInfo.hs")
                  pkgInfoMod

  lbi <- defaultConfHook (gpd', hbi) flags

  return (lbi {withOptimization = NoOptimisation})

-- | The entry point for @Setup.hs@ files in bindings.
setupHaskellGIBinding :: Text -- ^ name
                      -> Text -- ^ version
                      -> Bool -- ^ verbose
                      -> Maybe FilePath -- ^ overrides file
                      -> Maybe FilePath -- ^ output dir
                      -> IO ()
setupHaskellGIBinding name version verbose overridesFile outputDir =
    defaultMainWithHooks (simpleUserHooks {
                            confHook = confCodeGenHook name version verbose
                                       overridesFile outputDir
                                       (confHook simpleUserHooks)
                          })
