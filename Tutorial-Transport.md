

# 📦 **Detailed Tutorial: Understanding and Using `shipment-milestones.plutus`**

This tutorial explains the full structure and logic behind your Shipment Milestones validator, including its types, actions, milestone-based payout logic, dispute flow, NFT binding, and validator compilation.

---

## 📚 **Table of Contents**

1. [📦 Imports Overview](#1-imports-overview)
2. [📄 On-chain Data Types](#2-on-chain-data-types)
3. [🛠️ Helper Functions](#3-helper-functions)
4. [🧠 Core Validator Logic](#4-core-validator-logic)
5. [⚙️ Wrapping and Script Compilation](#5-wrapping-and-script-compilation)
6. [🧪 Practical Usage Example](#6-practical-usage-example)
7. [🧷 Testing Strategy](#7-testing-strategy)
8. [✨ Best Practices](#8-best-practices)
9. [📘 Glossary of Terms](#9-glossary-of-terms)

---

## 1. 📦 **Imports Overview**

### 🔹 **Plutus API Modules**

**Plutus.V2.Ledger.Api**
Provides core types:

* `ScriptContext`, `TxInfo`, `TxOut`
* `PubKeyHash`, `POSIXTime`
* `CurrencySymbol`, `TokenName`
* Validator compilation functions

**Plutus.V2.Ledger.Contexts**

* `txSignedBy` → Used to check signatures.

**Plutus.V1.Ledger.Interval**

* `contains`, `from` → Used to verify deadline-related logic (timestamps).

### 🔹 **Value / Serialization**

* `Ledger.Value` for reading token units inside outputs
* `Codec.Serialise` for script binary encoding
* `Cardano.Api.*` for writing the `.plutus` file

---

## 2. 📄 **On-chain Data Types**

### 🔹 **ShipmentStatus**

A simple enumerated state recorded off-chain:
`Pending`, `InTransit`, `Completed`, `Disputed`, `Cancelled`
*(Used for UI/state machines, not used directly in validator logic.)*

---

### 🔹 **ShipDatum**

Stores full state of a shipment escrow:

| Field                      | Meaning                                     |
| -------------------------- | ------------------------------------------- |
| `sdOwner`                  | Party who funds escrow (seller/platform)    |
| `sdCarrier`                | Carrier expected to complete milestones     |
| `sdNftCS`, `sdNftTN`       | Identifying NFT for the shipment            |
| `sdTotalMilestones`        | Total number of required proofs             |
| `sdCurrentMilestone`       | How many have been approved so far          |
| `sdPayoutPerMilestone`     | Token reward per approved milestone         |
| `sdCustodian`              | External trusted verifier signing approvals |
| `sdDeadline`               | Shipment deadline                           |
| `sdPayoutCS`, `sdPayoutTN` | Asset paid to the carrier                   |

---

### 🔹 **ShipAction**

Redeemers representing shipment actions:

| Action               | Description                                |
| -------------------- | ------------------------------------------ |
| **Fund**             | Owner initializes the escrow               |
| **SubmitProof**      | Carrier submits milestone evidence         |
| **ApproveMilestone** | Custodian approves proof & triggers payout |
| **Dispute**          | Owner/carrier disputes a milestone         |
| **Complete**         | Owner or custodian marks shipment complete |
| **Cancel**           | Owner cancels before full completion       |

---

## 3. 🛠️ **Helper Functions**

### 🔹 `pubKeyHashAddress`

Converts a pubkey hash into an address for payment checks.

### 🔹 `valuePaidTo`

Returns how much of a specific asset (CS/TN) is paid to an address in this transaction.

Used heavily in payout validation.

### 🔹 `nowInRange`

Ensures a timestamp is valid relative to the transaction’s interval.

### 🔹 `nftHeldByScript`

Checks if the NFT remains somewhere in transaction outputs.

---

## 4. 🧠 **Core Validator Logic**

The validator enforces milestone-based payouts, dispute handling, and proper signatures.

### 🔹 **`Fund`**

Requirements:

* Must be signed by **owner**
* `payoutPerMilestone` must be positive
* Off-chain code ensures correct escrow amount is locked

---

### 🔹 **`SubmitProof`**

Carrier submits a milestone proof:

* Must be signed by **carrier**
* Cannot exceed total milestones

---

### 🔹 **`ApproveMilestone`**

Critical escrow release logic:

Validates:

1. **Custodian signature**
2. **Milestones remain**
3. **Timestamp is valid**
4. **Carrier receives at least payoutPerMilestone tokens**

This is the actual payment execution step.

---

### 🔹 **`Dispute`**

Owner or carrier may dispute a milestone:

* Requires signature from owner *or* carrier

---

### 🔹 **`Complete`**

Mark shipment completed:

* Signed by owner or custodian
* Requires all milestones completed

---

### 🔹 **`Cancel`**

Cancel shipment early:

* Owner must sign
* Only allowed if milestones are not fully completed

---

## 5. ⚙️ **Wrapping and Script Compilation**

### `wrapped`

Converts datums + redeemers from `BuiltinData` → typed values.

### `validator`

Compiles the actual Plutus script using Template Haskell:

```haskell
validator = mkValidatorScript $$(PlutusTx.compile [|| wrapped ||])
```

---

## 6. 🧪 **Practical Usage Example**

```haskell
-- Compile and write the validator to a file
saveValidator

-- The file "shipment-milestones.plutus" is now ready for deployment.

-- Use this script when locking funds to initialize a shipment escrow.
```

Off-chain code would:

1. Construct `ShipDatum`
2. Lock escrow total = milestones × payoutPerMilestone
3. Introduce NFT or tracking metadata
4. Use appropriate redeemers per milestone

---

## 7. 🧷 **Testing Strategy**

You should test:

### 🔹 **Fund**

* Ensure owner must sign
* Ensure payout per milestone is >0

### 🔹 **SubmitProof**

* Signature by carrier only
* Cannot exceed milestones

### 🔹 **ApproveMilestone**

* Correct payout
* Custodian signature
* Timestamp inside valid range

### 🔹 **Dispute**

* Owner/carrier signatures

### 🔹 **Complete**

* Only after all milestones

### 🔹 **Cancel**

* Before all milestones complete

---

## 8. ✨ **Best Practices**

* Always simulate disputes and milestone failures
* Ensure off-chain code increments `sdCurrentMilestone`
* Add metadata logs for each milestone
* Use the NFT in UTxO to bind shipment identity
* Keep timestamps consistent with IoT oracle feeds

---

## 9. 📘 **Glossary of Terms**

| Term           | Definition                                       |
| -------------- | ------------------------------------------------ |
| **Escrow**     | On-chain locked funds awaiting conditions        |
| **Milestone**  | A unit of shipment progress requiring proof      |
| **Custodian**  | Trusted third party verifying proofs             |
| **Payout**     | Token release to carrier per milestone           |
| **Redeemer**   | Action submitted to validator                    |
| **Datum**      | Script state stored inside UTxO                  |
| **NFT**        | Unique token representing shipment identity      |
| **POSIXTime**  | Plutus timestamp format                          |
| **txSignedBy** | Signature check utility                          |
| **ValidRange** | The allowed execution interval for a transaction |

---

