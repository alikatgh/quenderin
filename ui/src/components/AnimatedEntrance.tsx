import React from 'react';

interface AnimatedEntranceProps {
    children: React.ReactNode;
    index?: number;
    className?: string;
}

export function AnimatedEntrance({ children, index = 0, className = '' }: AnimatedEntranceProps) {
    return (
        <div
            className={`animate-entrance ${className}`}
            style={{ '--entrance-index': index } as React.CSSProperties}
        >
            {children}
        </div>
    );
}
