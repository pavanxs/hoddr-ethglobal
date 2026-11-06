import type {Abi, Hex} from 'viem';
import type {Address, LocalAccount, NetworkKey} from '../types';

export type ContractName = 'LaunchpadFactory'|'LaunchSettlementVault'|'PhaseCapHook'|'BidLockFactory'|'BidLock'|'LaunchToken'|'IdentityRegistry'|'ENSDomainGateFactory'|'ENSDomainGate'|'ContinuousClearingAuction';
export interface SyntheticProof {root:string;nullifierHash:string;proof:string[]}
export interface Deployment {
  chainId:number; deploymentBlock:number; factory:Address; identityRegistry:Address; ensGateFactory:Address;
  poolManager:Address; positionManager:Address; wrapperFactory:Address; localTestOnly:boolean;
  accounts?:LocalAccount[]; syntheticProofs?:Record<string,SyntheticProof>;
  seededNames?:Record<string,string[]>; world?:{appId:string;action:string;environment:'staging';bridgeUrl?:string};
}
export interface Runtime {version:1;worldConfigured:boolean;abis:Record<ContractName,Abi>;deployments:Record<NetworkKey,Deployment|null>}
export interface ChainPhase {startBlock:bigint;endBlock:bigint;baseCapStart:bigint;baseCapEnd:bigint;verifiedCapStart:bigint;verifiedCapEnd:bigint;minimumBid:bigint;verifiedOnly:boolean;ensGate:Address}
export interface ChainLock {durationSeconds:bigint;multiplierBps:number}
export interface LaunchRecord {
 id:bigint;creator:Address;token:Address;auction:Address;validationHook:Address;settlement:Address;treasury:Address;
 startBlock:bigint;endBlock:bigint;claimBlock:bigint;totalSupply:bigint;reserveForLiquidity:bigint;
 floorPriceQ96:bigint;priceTickSpacing:bigint;requiredCurrencyRaised:bigint;poolFee:number;poolTickSpacing:number;
 liquidityAllocationMps:number;identityEnabled:boolean;name:string;symbol:string;metadataURI:string;
}
export interface Allowance {
 phaseIndex:bigint;currentBlock:bigint;wrapper:Address;identity:Hex;active:boolean;verified:boolean;
 identityRequired:boolean;ensRequired:boolean;identityAllowed:boolean;accountCommitted:bigint;committed:bigint;
 cap:bigint;remaining:bigint;minimumBid:bigint;effectiveLockOptionIndex:bigint;effectiveMultiplierBps:number;
}
export interface Bid {startBlock:bigint;startCumulativeMps:number;exitedBlock:bigint;maxPrice:bigint;owner:Address;amountQ96:bigint;tokensFilled:bigint}
export interface Checkpoint {clearingPrice:bigint;prev:bigint;next:bigint}
export interface EnsInspection {eligible:boolean;reason:number;registry:Address;owner:Address;expiry:bigint;labelIndex:bigint;inParentPath:boolean}
