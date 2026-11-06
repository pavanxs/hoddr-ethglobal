/** UI boundary. Amounts are human-readable decimal strings; chain conversion lives in src/chain. */
export type Address = `0x${string}`;
export type NetworkKey = 'local' | 'sepolia';
export type ProviderKey = 'none' | 'world-id' | 'zkpassport' | 'ace';
export type LaunchStatus = 'upcoming' | 'live' | 'settling' | 'graduated' | 'failed';
export type Tone = 'neutral' | 'success' | 'warning' | 'danger' | 'accent';

export interface Asset { address: Address; symbol: string; name: string; decimals: number; native?: boolean }
export interface NetworkState { key: NetworkKey; name: string; chainId: number; blockNumber: number; timestamp: number; connected: boolean; explorerUrl?: string }
export interface AccountState { address: Address; nativeBalance: string; quoteBalance: string; mode: 'local' | 'wallet'; verified: boolean; identitySource?: string; syntheticIdentity?: boolean; linkedWalletCount?: number; ensName?: string }
export interface LocalAccount { address: Address; label: string; description?: string }
export interface ProviderState { key: ProviderKey; name: string; status: 'ready' | 'local-fixture' | 'not-configured' | 'unavailable'; description: string }

export interface PhaseDraft {
  id: string; name: string; durationBlocks: number; minimumBid: string;
  baseCapStart: string; baseCapEnd: string; verifiedCapStart: string; verifiedCapEnd: string;
  requireVerified: boolean; requireEns: boolean;
}
export interface LockDraft { id: string; durationDays: number; multiplierBps: number }
export interface LaunchDraft {
  name: string; symbol: string; description: string; totalSupply: string;
  saleBps: number; liquidityBps: number; floorPrice: string; minimumRaise: string;
  startDelayBlocks: number; quoteAsset: Address; provider: ProviderKey; ensDomain: string;
  phases: PhaseDraft[]; locks: LockDraft[];
}
export interface LaunchPhase extends PhaseDraft { startBlock: number; endBlock: number }
export interface EligibilityState {
  eligible: boolean; verified: boolean; syntheticIdentity?: boolean; identitySource?: string;
  tier: 'base' | 'verified'; ensRequired: boolean; ensName?: string; ensSatisfied: boolean; reason?: string;
  currentCap: string; cumulativeSpend: string; remaining: string; minimumBid: string;
  linkedWalletCount: number; effectiveMultiplierBps: number; effectiveLockDays?: number; priorSpendIncluded?: boolean;
}
export interface Launch {
  id: string; name: string; symbol: string; description: string; creator: Address;
  tokenAddress: Address; auctionAddress: Address; poolAddress?: Address; poolId?: Address; hookAddress?: Address;
  status: LaunchStatus; createdAt?: number; totalSupply: string; saleSupply: string; liquiditySupply: string;
  raised: string; minimumRaise: string; floorPrice: string; currentPrice?: string; totalBids: number; participantCount?: number;
  startBlock: number; endBlock: number; currentPhaseIndex: number | null;
  phases: LaunchPhase[]; locks: LockDraft[]; provider: ProviderKey; ensDomain?: string; quoteAsset: Asset;
  treasury?: { address: Address; nativeAmount: string; tokenAmount: string; positionId?: string; positionReleased: boolean; canReleaseProceeds: boolean; canReleasePosition: boolean };
  eligibility?: EligibilityState; canMigrate: boolean; migrationUnavailableReason?: string; accent?: 'mint' | 'violet' | 'peach' | 'blue';
}
export interface PositionActions { settle: boolean; claim: boolean; refund: boolean; unlock: boolean }
export interface Position {
  id: string; launchId: string; launchName: string; symbol: string; owner: Address; beneficiary: Address; wrapperAddress?: Address; bidId?: string; bidCount?: number;
  amount: string; maxPrice: string; quoteAsset: Asset; allocatedTokens: string; claimableTokens: string; refundableAmount: string;
  lockedTokens: string; unlockedTokens?: string; lockDays: number; unlockAt?: number; phaseName?: string;
  status: 'active' | 'ready' | 'locked' | 'complete' | 'refundable'; actions: PositionActions; unavailableReason?: string;
}
export interface Activity { id: string; title: string; description: string; timestamp: number; status: 'pending' | 'confirmed' | 'failed'; hash?: Address; launchId?: string; chainId?: number }
export interface AppSnapshot {
  launchpadDeployed?: boolean;
  network: NetworkState; account?: AccountState; quoteAsset: Asset; launches: Launch[]; positions: Position[]; activity: Activity[];
  providers: ProviderState[]; localAccounts?: LocalAccount[]; limits?: { maxPhases: number; maxLocks: number; maxLinkedWallets: number }; notices?: string[];
}
export interface BidInput { amount: string; maxPrice: string; lockDays: number; ensName?: string; requestedUnlockAt?: number }
export interface EnsCheckResult { name: string; valid: boolean; owner?: Address; reason?: string }
export interface VerificationProgress {
  status: 'requesting' | 'awaiting-user' | 'checking' | 'submitting' | 'confirmed' | 'cancelled' | 'error';
  message: string; connectorUrl?: string; qrDataUrl?: string; hash?: Address; synthetic?: boolean;
}
export interface TransactionResult { hash: Address; chainId: number; label: string; receiptBlock?: number; launchId?: string; positionId?: string }
export interface LaunchpadClient {
  getSnapshot(): Promise<AppSnapshot>;
  setNetwork(network: NetworkKey): Promise<void>;
  connectWallet(): Promise<void>;
  selectAccount(address: Address): Promise<void>;
  createLaunch(draft: LaunchDraft): Promise<TransactionResult>;
  placeBid(launchId: string, input: BidInput): Promise<TransactionResult>;
  verifyHuman(onProgress: (state: VerificationProgress) => void): Promise<TransactionResult | void>;
  cancelVerification(): void;
  checkEns(launchId: string, name: string): Promise<EnsCheckResult>;
  previewEligibility?(launchId: string, input: { lockDays: number; ensName?: string }): Promise<EligibilityState>;
  settle(positionId: string): Promise<TransactionResult>;
  claim(positionId: string): Promise<TransactionResult>;
  refund(positionId: string): Promise<TransactionResult>;
  unlock(positionId: string): Promise<TransactionResult>;
  checkpoint?(launchId: string): Promise<TransactionResult>;
  migrate(launchId: string): Promise<TransactionResult>;
  releaseProceeds?(launchId: string): Promise<TransactionResult>;
  releasePosition?(launchId: string): Promise<TransactionResult>;
  advanceBlocks(count: number): Promise<void>;
  advanceTime?(seconds: number): Promise<void>;
}
