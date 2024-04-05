{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE DerivingStrategies   #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -Wno-orphans #-}

module Ouroboros.Consensus.Shelley.Node.DiffusionPipelining (
    HotIdentity (..)
  , ShelleyTentativeHeaderState (..)
  , ShelleyTentativeHeaderView (..)
  ) where

import qualified Cardano.Ledger.Shelley.API as SL
import           Control.Monad (guard)
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Word
import           GHC.Generics (Generic)
import           NoThunks.Class
import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Protocol.Abstract
import           Ouroboros.Consensus.Shelley.Eras (isBeforeConway)
import           Ouroboros.Consensus.Shelley.Ledger.Block
import           Ouroboros.Consensus.Shelley.Ledger.Protocol ()
import           Ouroboros.Consensus.Shelley.Protocol.Abstract
import           Ouroboros.Consensus.Util

-- | Hot block issuer identity for the purpose of Shelley block diffusion
-- pipelining.
data HotIdentity c = HotIdentity {
    -- | Hash of the cold key.
    hiIssuer  :: !(SL.KeyHash SL.BlockIssuer c)
  , -- | The issue number/opcert counter. Even if the opcert was compromised and
    -- hence an attacker forges blocks with a specific cold identity, the owner
    -- of the cold key can issue a new opcert with an incremented counter, and
    -- their minted blocks will be pipelined.
    hiIssueNo :: !Word64
  }
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (NoThunks)

data ShelleyTentativeHeaderState proto =
    -- | Legacy state, can be removed once mainnet is in Conway.
    LegacyShelleyTentativeHeaderState !(SelectViewTentativeState proto)
  | ShelleyTentativeHeaderState
      -- | The block number of the last trap tentative header.
      !(WithOrigin BlockNo)
      -- | The set of all hot identies of those who issued trap tentative
      -- headers for the recorded block number.
      --
      -- Remember that 'TentativeHeaderState's are maintained in different
      -- contexts, and we might record different identities per block number in
      -- them:
      --
      --  - In ChainSel, we record all identities of trap headers we sent.
      --
      --  - In the BlockFetch punishment logic, for each upstream peer, we
      --    record the identities of trap headers they sent.
      !(Set (HotIdentity (ProtoCrypto proto)))
  deriving stock (Show, Eq, Generic)
  deriving anyclass (NoThunks)

data ShelleyTentativeHeaderView proto =
    -- | Legacy state, can be removed once mainnet is in Conway.
    LegacyShelleyTentativeHeaderView (SelectView proto)
  | ShelleyTentativeHeaderView BlockNo (HotIdentity (ProtoCrypto proto))

deriving stock instance ConsensusProtocol proto => Show (ShelleyTentativeHeaderView proto)
deriving stock instance ConsensusProtocol proto => Eq   (ShelleyTentativeHeaderView proto)

-- | This is currently a hybrid instance:
--
--  - For eras before Conway, this uses the logic from
--    'SelectViewDiffusionPipelining' for backwards-compatibility.
--
--  - For all eras since Conway, this uses a new scheme: A header can be
--    pipelined iff no trap header with the same block number and by the same
--    issuer was pipelined before. See 'HotIdentity' for what exactly we use for
--    the issuer identity.
--
-- Once mainnet has transitioned to Conway, we can remove the pre-Conway logic
-- here.
instance
  ( ShelleyCompatible proto era
  , BlockSupportsProtocol (ShelleyBlock proto era)
  ) => BlockSupportsDiffusionPipelining (ShelleyBlock proto era) where
  type TentativeHeaderState (ShelleyBlock proto era) =
    ShelleyTentativeHeaderState proto

  type TentativeHeaderView (ShelleyBlock proto era) =
    ShelleyTentativeHeaderView proto

  initialTentativeHeaderState _
    | isBeforeConway (Proxy @era)
    = LegacyShelleyTentativeHeaderState NoLastInvalidSelectView
    | otherwise
    = ShelleyTentativeHeaderState Origin Set.empty

  tentativeHeaderView
    | isBeforeConway (Proxy @era)
    = LegacyShelleyTentativeHeaderView .: selectView
    | otherwise
    = \_bcfg hdr@(ShelleyHeader sph _) ->
        ShelleyTentativeHeaderView (blockNo hdr) HotIdentity {
            hiIssuer  = SL.hashKey $ pHeaderIssuer sph
          , hiIssueNo = pHeaderIssueNo sph
          }

  applyTentativeHeaderView _ thv st
    | LegacyShelleyTentativeHeaderView thv' <- thv
    , LegacyShelleyTentativeHeaderState st' <- st
    = LegacyShelleyTentativeHeaderState <$>
        applyTentativeHeaderView
          (Proxy @(SelectViewDiffusionPipelining (ShelleyBlock proto era)))
          thv'
          st'
    | ShelleyTentativeHeaderView bno hdrIdentity <- thv
    , ShelleyTentativeHeaderState lastBlockNo badIdentities <- st
    = case compare (NotOrigin bno) lastBlockNo of
        LT -> Nothing
        EQ -> do
          guard $ hdrIdentity `Set.notMember` badIdentities
          Just $ ShelleyTentativeHeaderState
            lastBlockNo
            (Set.insert hdrIdentity badIdentities)
        GT ->
          Just $ ShelleyTentativeHeaderState
            (NotOrigin bno)
            (Set.singleton hdrIdentity)
    -- Inconsistent tentative header view vs state. This case can be removed
    -- once mainnet has transitioned to Conway.
    | otherwise = error "impossible"
