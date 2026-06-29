import { Component, type ReactNode } from 'react';

interface Props {
    children: ReactNode;
    fallbackLabel?: string;
}

interface State {
    hasError: boolean;
    error: Error | null;
}

export class ErrorBoundary extends Component<Props, State> {
    state: State = { hasError: false, error: null };

    static getDerivedStateFromError(error: Error): State {
        return { hasError: true, error };
    }

    componentDidCatch(error: Error, info: { componentStack: string }) {
        console.error(`[ErrorBoundary] ${this.props.fallbackLabel ?? 'section'} crashed:`, error, info.componentStack);
    }

    handleRetry = () => {
        this.setState({ hasError: false, error: null });
    };

    render() {
        if (this.state.hasError) {
            return (
                <div role="alert" className="flex flex-col items-center justify-center h-full gap-3 p-6 text-center">
                    <p className="text-sm text-zinc-500 dark:text-zinc-400">
                        {this.props.fallbackLabel ?? 'This section'} failed to load.
                    </p>
                    <button
                        type="button"
                        onClick={this.handleRetry}
                        className="px-3 py-1.5 text-xs font-semibold rounded-lg border border-zinc-300 dark:border-zinc-700 text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
                    >
                        Try again
                    </button>
                </div>
            );
        }
        return this.props.children;
    }
}
