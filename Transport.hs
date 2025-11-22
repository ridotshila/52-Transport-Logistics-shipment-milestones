{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DerivingStrategies  #-}

module Main where

import Prelude (IO, print, putStrLn, String)
import qualified Prelude as H

import PlutusTx
import PlutusTx.Prelude        hiding (Semigroup(..), unless, ($))
import Plutus.V2.Ledger.Api
  ( BuiltinData
  , ScriptContext (..)
  , TxInfo (..)
  , TxOut (..)
  , Validator
  , mkValidatorScript
  , PubKeyHash
  , Address (..)
  , Credential (..)
  , POSIXTime
  , CurrencySymbol
  , TokenName
  , txInfoValidRange
  )
import Plutus.V2.Ledger.Contexts (txSignedBy)
import Plutus.V1.Ledger.Interval (contains, from)
import qualified Plutus.V1.Ledger.Value as Value

import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Short as SBS
import Codec.Serialise (serialise)

import Cardano.Api (writeFileTextEnvelope)
import Cardano.Api.Shelley (PlutusScript (..), PlutusScriptV2)

------------------------------------------------------------------------------
-- On-chain types
------------------------------------------------------------------------------

-- Shipment status simplified: Pending, InTransit, Completed, Disputed, Cancelled
data ShipmentStatus = Pending | InTransit | Completed | Disputed | Cancelled
PlutusTx.unstableMakeIsData ''ShipmentStatus

-- ShipDatum:
-- - owner: the party who funded the escrow (e.g. seller / platform)
-- - carrier: the intended carrier PubKeyHash
-- - nftAsset: CurrencySymbol/TokenName that represent the Shipment NFT (for tracing)
-- - totalMilestones: number of milestones expected
-- - currentMilestone: index already completed (0-based)
-- - payoutPerMilestone: amount (in some token units) to release per milestone
-- - custodian: trusted party (e.g. IoT aggregator / custodian) who can approve proofs by signing
-- - deadline: overall deadline for the shipment (POSIXTime)
-- - payoutCS/payoutTN: token used to pay carriers (could be ADA or stable token)
data ShipDatum = ShipDatum
    { sdOwner             :: PubKeyHash
    , sdCarrier           :: PubKeyHash
    , sdNftCS             :: CurrencySymbol
    , sdNftTN             :: TokenName
    , sdTotalMilestones   :: Integer
    , sdCurrentMilestone  :: Integer
    , sdPayoutPerMilestone:: Integer
    , sdCustodian         :: PubKeyHash
    , sdDeadline          :: POSIXTime
    , sdPayoutCS          :: CurrencySymbol
    , sdPayoutTN          :: TokenName
    }
PlutusTx.unstableMakeIsData ''ShipDatum

-- Redeemer actions:
-- - Fund: fund the escrow (signed by owner)
-- - SubmitProof proofHash: carrier submits milestone proof (signed by carrier) — offchain will include proof on chain as datum or reference
-- - ApproveMilestone proofHash paidAt: custodian approves the proof (signed by custodian) and includes a timestamp
-- - Dispute reasonHash: any party can raise dispute (signed by owner or carrier) before approval
-- - Complete: owner or custodian can mark shipment complete if milestones done
-- - Cancel: owner can cancel (if not already completed)
data ShipAction = Fund
                | SubmitProof BuiltinByteString
                | ApproveMilestone BuiltinByteString POSIXTime
                | Dispute BuiltinByteString
                | Complete
                | Cancel
PlutusTx.unstableMakeIsData ''ShipAction

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

{-# INLINABLE pubKeyHashAddress #-}
pubKeyHashAddress :: PubKeyHash -> Address
pubKeyHashAddress pkh = Address (PubKeyCredential pkh) Nothing

{-# INLINABLE valuePaidTo #-}
-- Sum of a particular asset paid to a given pubkey in tx outputs
valuePaidTo :: TxInfo -> PubKeyHash -> CurrencySymbol -> TokenName -> Integer
valuePaidTo info pkh cs tn =
    let outs = txInfoOutputs info
        matches = [ Value.valueOf (txOutValue o) cs tn
                  | o <- outs
                  , txOutAddress o == pubKeyHashAddress pkh
                  ]
    in foldr (+) 0 matches

{-# INLINABLE nowInRange #-}
-- Check if the tx's valid range includes a POSIXTime >= t (i.e. time t is reachable in this tx)
nowInRange :: TxInfo -> POSIXTime -> Bool
nowInRange info t = contains (from t) (txInfoValidRange info)

{-# INLINABLE nftHeldByScript #-}
-- Optionally check whether the script outputs still include the NFT (best-effort).
-- This function checks that *some* output pays the NFT (cs,tn) to a script or address;
-- on-chain guarantees about NFT movement should be enforced off-chain by consuming the script UTxO.
nftHeldByScript :: TxInfo -> CurrencySymbol -> TokenName -> Bool
nftHeldByScript info cs tn =
    let outs = txInfoOutputs info
        matches = [ Value.valueOf (txOutValue o) cs tn
                  | o <- outs
                  ]
    in foldr (+) 0 matches > 0

------------------------------------------------------------------------------
-- Core validator
------------------------------------------------------------------------------

{-# INLINABLE mkShipmentValidator #-}
mkShipmentValidator :: ShipDatum -> ShipAction -> ScriptContext -> Bool
mkShipmentValidator sd action ctx =
    case action of

      Fund ->
        -- Owner must sign funding tx. Off-chain should ensure enough tokens (totalMilestones * payoutPerMilestone) are included.
        traceIfFalse "fund: owner signature required" (txSignedBy info (sdOwner sd))
        && traceIfFalse "fund: positive payoutPerMilestone" (sdPayoutPerMilestone sd > 0)
        where
          info = scriptContextTxInfo ctx

      SubmitProof proofHash ->
        -- Carrier submits proof for next milestone. Carrier must sign. We don't check proof content on-chain.
        traceIfFalse "submit: carrier signature required" (txSignedBy info (sdCarrier sd))
        && traceIfFalse "submit: cannot submit if already completed" (sdCurrentMilestone sd < sdTotalMilestones sd)
        where
          info = scriptContextTxInfo ctx

      ApproveMilestone proofHash paidAt ->
        -- Custodian approves the proof and this must release funds to carrier.
        -- Checks:
        --  - vault still armed (i.e. milestones remain)
        --  - custodian signature present
        --  - paidAt reachable in tx (freshness)
        --  - recipient (carrier) receives at least payoutPerMilestone in this tx
        --  - current milestone increments by 1 (off-chain)
        traceIfFalse "approve: custodian signature required" (txSignedBy info (sdCustodian sd))
        && traceIfFalse "approve: still milestones remaining" (sdCurrentMilestone sd < sdTotalMilestones sd)
        && traceIfFalse "approve: paidAt reachable in tx" (nowInRange info paidAt)
        && traceIfFalse "approve: carrier must be paid payoutPerMilestone" (valuePaidTo info (sdCarrier sd) (sdPayoutCS sd) (sdPayoutTN sd) >= sdPayoutPerMilestone sd)
        where
          info = scriptContextTxInfo ctx

      Dispute reasonHash ->
        -- Dispute can be raised by owner or carrier (signed). It moves state to Disputed (off-chain) for adjudication.
        traceIfFalse "dispute: owner or carrier must sign" (txSignedBy info (sdOwner sd) || txSignedBy info (sdCarrier sd))
        where
          info = scriptContextTxInfo ctx

      Complete ->
        -- Only owner or custodian can mark complete. Must have completed all milestones.
        traceIfFalse "complete: owner or custodian signature required" (txSignedBy info (sdOwner sd) || txSignedBy info (sdCustodian sd))
        && traceIfFalse "complete: all milestones must be done" (sdCurrentMilestone sd >= sdTotalMilestones sd)
        where
          info = scriptContextTxInfo ctx

      Cancel ->
        -- Owner can cancel before completion; off-chain must refund carrier if partial paid.
        traceIfFalse "cancel: owner signature required" (txSignedBy info (sdOwner sd))
        && traceIfFalse "cancel: cannot cancel after completion" (sdCurrentMilestone sd < sdTotalMilestones sd)
        where
          info = scriptContextTxInfo ctx

------------------------------------------------------------------------------
-- Wrapping
------------------------------------------------------------------------------

{-# INLINABLE wrapped #-}
wrapped :: BuiltinData -> BuiltinData -> BuiltinData -> ()
wrapped d r c =
    let sd  = unsafeFromBuiltinData d :: ShipDatum
        act = unsafeFromBuiltinData r :: ShipAction
        ctx = unsafeFromBuiltinData c :: ScriptContext
    in if mkShipmentValidator sd act ctx
         then ()
         else traceError "ShipmentMilestones: validation failed"

validator :: Validator
validator = mkValidatorScript $$(PlutusTx.compile [|| wrapped ||])

------------------------------------------------------------------------------
-- Write validator to file
------------------------------------------------------------------------------

saveValidator :: IO ()
saveValidator = do
    let scriptSerialised = serialise validator
        scriptShortBs    = SBS.toShort (LBS.toStrict scriptSerialised)
        plutusScript     = PlutusScriptSerialised scriptShortBs :: PlutusScript PlutusScriptV2
    r <- writeFileTextEnvelope "shipment-milestones.plutus" Nothing plutusScript
    case r of
      Left err -> print err
      Right () -> putStrLn "Shipment milestones validator written to: shipment-milestones.plutus"

main :: IO ()
main = saveValidator
