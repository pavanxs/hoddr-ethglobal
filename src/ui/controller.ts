import { useCallback, useEffect, useRef, useState } from 'react';
import type { AppSnapshot, LaunchpadClient, TransactionResult, VerificationProgress } from '../types';
import { errorMessage } from './format';

export interface ToastState { id: number; title: string; message?: string; tone: 'success' | 'danger' | 'neutral'; hash?: string; chainId?: number }
export interface RunOptions { success?: string; silent?: boolean; contextChange?: boolean }
export type RunAction = (label: string, task: () => Promise<TransactionResult | void>, options?: RunOptions) => Promise<TransactionResult | undefined>;

export function useLaunchpad(client: LaunchpadClient) {
  const [snapshot, setSnapshot] = useState<AppSnapshot>();
  const [reading, setReading] = useState(true);
  const [readError, setReadError] = useState('');
  const [operation, setOperation] = useState<string>();
  const [toast, setToast] = useState<ToastState>();
  const [verification, setVerification] = useState<VerificationProgress>();
  const mounted = useRef(true);
  const epoch = useRef(0);
  const readSequence = useRef(0);
  const activeRead = useRef<{ epoch: number; promise: Promise<void> } | undefined>(undefined);
  const busy = useRef(false);
  const operationSequence = useRef(0);
  const verificationSequence = useRef(0);
  const verificationCancelled = useRef(false);

  const refresh = useCallback((force = false): Promise<void> => {
    const currentEpoch = epoch.current;
    if (!force && activeRead.current?.epoch === currentEpoch) return activeRead.current.promise;
    const sequence = ++readSequence.current;
    setReading(true);
    const promise: Promise<void> = client.getSnapshot().then(next => {
      if (!mounted.current || epoch.current !== currentEpoch || sequence !== readSequence.current) return;
      setSnapshot(next);
      setReadError('');
    }).catch(error => {
      if (!mounted.current || epoch.current !== currentEpoch || sequence !== readSequence.current) return;
      setReadError(errorMessage(error));
    }).finally(() => {
      if (activeRead.current?.promise === promise) activeRead.current = undefined;
      if (mounted.current && sequence === readSequence.current) setReading(false);
    });
    activeRead.current = { epoch: currentEpoch, promise };
    return promise;
  }, [client]);

  useEffect(() => {
    mounted.current = true;
    void refresh();
    const timer = window.setInterval(() => { if (document.visibilityState !== 'hidden') void refresh(); }, 5000);
    const visible = () => { if (document.visibilityState === 'visible') void refresh(); };
    document.addEventListener('visibilitychange', visible);
    return () => { mounted.current = false; window.clearInterval(timer); document.removeEventListener('visibilitychange', visible); };
  }, [refresh]);

  const run: RunAction = useCallback(async (label, task, options = {}) => {
    if (busy.current) return undefined;
    busy.current = true;
    const sequence = ++operationSequence.current;
    if (options.contextChange) { epoch.current += 1; readSequence.current += 1; }
    setOperation(label);
    try {
      const result = await task();
      if (!mounted.current || sequence !== operationSequence.current) return undefined;
      if (options.contextChange) { setSnapshot(undefined); setVerification(undefined); }
      if (!options.silent) setToast({ id: Date.now(), title: options.success ?? result?.label ?? label, message: result?.hash ? 'Confirmed onchain.' : undefined, tone: 'success', hash: result?.hash, chainId: result?.chainId });
      await refresh(true);
      return result || undefined;
    } catch (error) {
      if (mounted.current && sequence === operationSequence.current) setToast({ id: Date.now(), title: 'Action needs attention', message: errorMessage(error), tone: 'danger' });
      await refresh(true);
      return undefined;
    } finally {
      if (sequence === operationSequence.current) { busy.current = false; if (mounted.current) setOperation(undefined); }
    }
  }, [refresh]);

  const verifyHuman = useCallback(async () => {
    if (busy.current) return;
    const sequence = ++verificationSequence.current;
    verificationCancelled.current = false;
    setVerification({ status: 'requesting', message: 'Preparing your verification request…' });
    await run('Verifying identity', async () => {
      try {
        return await client.verifyHuman(progress => {
          if (mounted.current && sequence === verificationSequence.current && !verificationCancelled.current) setVerification(progress);
        });
      } catch (error) {
        if (verificationCancelled.current) return;
        if (mounted.current && sequence === verificationSequence.current) setVerification({ status: 'error', message: errorMessage(error) });
        throw error;
      }
    }, { silent: true });
  }, [client, run]);

  const cancelVerification = useCallback(() => {
    verificationCancelled.current = true;
    verificationSequence.current += 1;
    client.cancelVerification();
    setVerification({ status: 'cancelled', message: 'Verification request cancelled.' });
  }, [client]);

  const notify = useCallback((title: string, message?: string, tone: ToastState['tone'] = 'neutral') => setToast({ id: Date.now(), title, message, tone }), []);
  return { snapshot, reading, readError, operation, toast, verification, run, refresh, verifyHuman, cancelVerification, notify, dismissToast: () => setToast(undefined), isBusy: Boolean(operation), actionsBlocked: Boolean(operation || readError || !snapshot?.network.connected) };
}
export type LaunchpadController = ReturnType<typeof useLaunchpad>;
