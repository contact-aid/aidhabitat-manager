import { useEffect, useRef, useState } from 'react';
import { VisitRecommendationItem } from '../../types';
import { fetchVisitRecommendations, saveVisitRecommendations } from '../../services/dataService';

export function useVisitRecommendations(dossierId: string) {
    const current = useRef({ dossierId, items: [] as VisitRecommendationItem[], ready: false });
    const [state, setState] = useState(current.current);
    const [error, setError] = useState<string | null>(null);

    useEffect(() => {
        let cancelled = false;
        current.current = { dossierId, items: [], ready: false };
        setState(current.current);
        setError(null);
        if (dossierId.startsWith('temp-')) return;
        fetchVisitRecommendations(dossierId).then((items) => {
            if (cancelled) return;
            current.current = { dossierId, items, ready: true };
            setState(current.current);
        }).catch(() => {
            if (!cancelled) setError('Chargement des préconisations impossible. Rouvrez le dossier pour réessayer.');
        });
        return () => { cancelled = true; };
    }, [dossierId]);

    const update = (change: (items: VisitRecommendationItem[]) => VisitRecommendationItem[]) => {
        const previous = current.current;
        if (previous.dossierId !== dossierId || !previous.ready) return;
        const items = change(previous.items);
        // This service writes the cache and durable sync queue synchronously,
        // before its promise resolves. Navigation can unmount us immediately.
        void saveVisitRecommendations(dossierId, items).catch((error) => {
            console.error('Failed to save recommendations', error);
        });
        current.current = { dossierId, items, ready: true };
        setState(current.current);
    };

    return {
        items: state.dossierId === dossierId ? state.items : [],
        ready: state.dossierId === dossierId && state.ready,
        error,
        update,
    };
}
