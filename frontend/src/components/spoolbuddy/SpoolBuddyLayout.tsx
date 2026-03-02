import { useState, useEffect, useRef, useCallback } from 'react';
import { Outlet } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { SpoolBuddyTopBar } from './SpoolBuddyTopBar';
import { SpoolBuddyBottomNav } from './SpoolBuddyBottomNav';
import { SpoolBuddyStatusBar } from './SpoolBuddyStatusBar';
import { useSpoolBuddyState } from '../../hooks/useSpoolBuddyState';
import { spoolbuddyApi } from '../../api/client';
import { VirtualKeyboard } from '../VirtualKeyboard';

export function SpoolBuddyLayout() {
  const [selectedPrinterId, setSelectedPrinterId] = useState<number | null>(null);
  const [alert, setAlert] = useState<{ type: 'warning' | 'error' | 'info'; message: string } | null>(null);
  const [blanked, setBlanked] = useState(false);
  const lastActivityRef = useRef(Date.now());
  const sbState = useSpoolBuddyState();

  // Query device data for display settings (brightness + blank timeout)
  const { data: devices = [] } = useQuery({
    queryKey: ['spoolbuddy-devices'],
    queryFn: () => spoolbuddyApi.getDevices(),
    refetchInterval: 15000,
  });
  const device = devices[0];
  const brightness = device?.display_brightness ?? 100;
  const blankTimeout = device?.display_blank_timeout ?? 0;

  // Force dark theme on mount, restore on unmount
  useEffect(() => {
    const root = document.documentElement;
    const hadDark = root.classList.contains('dark');
    root.classList.add('dark');
    return () => {
      if (!hadDark) root.classList.remove('dark');
    };
  }, []);

  // Update alert based on device state
  useEffect(() => {
    if (!sbState.deviceOnline) {
      setAlert({ type: 'warning', message: 'SpoolBuddy device disconnected' });
    } else {
      setAlert(null);
    }
  }, [sbState.deviceOnline]);

  // Track user activity for screen blank
  const resetActivity = useCallback(() => {
    lastActivityRef.current = Date.now();
    setBlanked(false);
  }, []);

  useEffect(() => {
    window.addEventListener('pointerdown', resetActivity);
    window.addEventListener('keydown', resetActivity);
    return () => {
      window.removeEventListener('pointerdown', resetActivity);
      window.removeEventListener('keydown', resetActivity);
    };
  }, [resetActivity]);

  // Reset on NFC/scale activity (WebSocket events)
  const prevWeightRef = useRef(sbState.weight);
  const prevSpoolRef = useRef(sbState.matchedSpool);
  const prevTagRef = useRef(sbState.unknownTagUid);
  useEffect(() => {
    if (
      sbState.weight !== prevWeightRef.current ||
      sbState.matchedSpool !== prevSpoolRef.current ||
      sbState.unknownTagUid !== prevTagRef.current
    ) {
      prevWeightRef.current = sbState.weight;
      prevSpoolRef.current = sbState.matchedSpool;
      prevTagRef.current = sbState.unknownTagUid;
      lastActivityRef.current = Date.now();
      setBlanked(false);
    }
  }, [sbState.weight, sbState.matchedSpool, sbState.unknownTagUid]);

  // Screen blank timer
  useEffect(() => {
    if (blankTimeout <= 0) return;
    const interval = setInterval(() => {
      if (Date.now() - lastActivityRef.current >= blankTimeout * 1000) {
        setBlanked(true);
      }
    }, 1000);
    return () => clearInterval(interval);
  }, [blankTimeout]);

  // CSS brightness filter (software dimming for HDMI displays)
  const brightnessStyle = brightness < 100
    ? { filter: `brightness(${brightness / 100})` } as const
    : undefined;

  return (
    <>
      <div
        className="w-screen h-screen bg-bambu-dark text-white flex flex-col overflow-hidden"
        style={brightnessStyle}
      >
        <SpoolBuddyTopBar
          selectedPrinterId={selectedPrinterId}
          onPrinterChange={setSelectedPrinterId}
          deviceOnline={sbState.deviceOnline}
        />

        <main className="flex-1 overflow-y-auto">
          <Outlet context={{ selectedPrinterId, setSelectedPrinterId, sbState, setAlert }} />
        </main>

        <SpoolBuddyStatusBar alert={alert} />
        <SpoolBuddyBottomNav />
        <VirtualKeyboard />
      </div>

      {/* Screen blank overlay — touch to wake */}
      {blanked && (
        <div
          className="fixed inset-0 bg-black z-[9999]"
          onPointerDown={(e) => { e.stopPropagation(); resetActivity(); }}
        />
      )}
    </>
  );
}

// Hook for child pages to access shared context
export interface SpoolBuddyOutletContext {
  selectedPrinterId: number | null;
  setSelectedPrinterId: (id: number) => void;
  sbState: ReturnType<typeof useSpoolBuddyState>;
  setAlert: (alert: { type: 'warning' | 'error' | 'info'; message: string } | null) => void;
}
