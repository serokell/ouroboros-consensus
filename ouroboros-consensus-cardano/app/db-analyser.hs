{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Database analysis tool.
--
-- Usage: db-analyser --db PATH [--verbose]
--                    [--only-immutable-db [--analyse-from SLOT_NUMBER]]
--                    [--validate-all-blocks | --minimum-block-validation]
--                    [--show-slot-block-no | --count-tx-outputs |
--                      --show-block-header-size | --show-block-txs-size |
--                      --show-ebbs | --store-ledger SLOT_NUMBER | --count-blocks |
--                      --checkThunks BLOCK_COUNT | --trace-ledger |
--                      --repro-mempool-and-forge INT | --benchmark-ledger-ops
--                      [--out-file FILE]] [--num-blocks-to-process INT] COMMAND
module Main (main) where

import           Cardano.Crypto.Init (cryptoInit)
import           Cardano.Tools.DBAnalyser.Run
import           Cardano.Tools.DBAnalyser.Types
import           Control.Monad (void)
import           DBAnalyser.Parsers
import           Options.Applicative (execParser, fullDesc, helper, info,
                     progDesc, (<**>))


main :: IO ()
main = do
    cryptoInit
    (conf, blocktype) <- getCmdLine
    void $ case blocktype of
      ByronBlock   args -> analyse conf args
      ShelleyBlock args -> analyse conf args
      CardanoBlock args -> analyse conf args

getCmdLine :: IO (DBAnalyserConfig, BlockType)
getCmdLine = execParser opts
  where
    opts = info (parseCmdLine <**> helper) (mconcat [
          fullDesc
        , progDesc "Simple framework used to analyse a Chain DB"
        ])
