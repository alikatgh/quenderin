/** Explicit publisher framing for models the older Node wrapper catalog cannot recognize. */
export function jaisChatWrapper(bindings: {
    ChatWrapper: any; LlamaText: any; SpecialTokensText: any; SpecialToken: any;
}): any {
    const { ChatWrapper, LlamaText, SpecialTokensText, SpecialToken } = bindings;
    const special = (value: string) => LlamaText(new SpecialTokensText(value));
    return new class extends ChatWrapper {
        wrapperName = 'Jais 3 text';
        settings = {
            ...ChatWrapper.defaultSettings,
            supportsSystemMessages: true,
            segments: {
                thought: { prefix: special('<ifm|think_faster>\n'), suffix: special('</ifm|think>') },
                closeAllSegments: special('</ifm|think_faster>'),
            },
        };
        generateContextState({ chatHistory, availableFunctions }: any) {
            if (availableFunctions && Object.keys(availableFunctions).length) {
                throw new Error('Jais 3 currently supports text chat only.');
            }
            const parts: any[] = [new SpecialToken('BOS')];
            let generating = false;
            for (let index = 0; index < chatHistory.length; index++) {
                const item = chatHistory[index];
                if (item.type === 'system' || item.type === 'user') {
                    parts.push(special(`<|ifm|im_start|>${item.type}\n`),
                        item.type === 'system' ? LlamaText.fromJSON(item.text) : LlamaText(item.text),
                        special('<|ifm|im_end|>'));
                } else if (item.type === 'model') {
                    if (index === chatHistory.length - 1) {
                        generating = true;
                        parts.push(special('<|ifm|im_start|>assistant\n'), this.generateModelResponseText(item.response));
                    } else {
                        // History contains final assistant text; publisher framing requires an
                        // explicit empty reasoning segment, with no newline after the role.
                        parts.push(special('<|ifm|im_start|>assistant<ifm|think>\n</ifm|think>'),
                            LlamaText(item.response.filter((part: any) => typeof part === 'string')),
                            special('<|ifm|im_end|>'));
                    }
                }
            }
            if (!generating) parts.push(special('<|ifm|im_start|>assistant\n'));
            const last = chatHistory[chatHistory.length - 1];
            return {
                contextText: LlamaText(parts),
                stopGenerationTriggers: [special('<|ifm|im_end|>'), LlamaText(new SpecialToken('EOS'))],
                ...(last?.type !== 'model' || last.response.length === 0 ? {
                    noPrefixTrigger: { type: 'segment', segmentType: 'thought', inject: special('<ifm|think_faster>\n') },
                } : {}),
            };
        }
    }();
}
