#!/usr/bin/env python3
"""
gen_strings.py — generate Android string resources for en + ru/ko/ja/zh-Hans.

Source of truth for translations is ../../scripts/translations.tsv (the same file
that drives iOS Localizable.xcstrings). TSV rows win; Android-only strings use the
EXTRAS dict below. A build-time guard hard-fails if an EXTRAS key shadows a TSV row,
so the two can never silently fork.

Emits: app/src/main/res/values{,-ru,-ko,-ja,-zh-rCN}/strings.xml
   and: app/src/main/res/xml/locales_config.xml (from LANGS — the per-app language
        picker can't drift from the shipped resource locales).
Existing resource rows outside RES are preserved verbatim when regenerating.
Resource ids come from RES (id -> english). %1$s/%1$d format strings are declared
here verbatim so aapt/lint validate specifier parity across every locale.

Importable without side effects: `from gen_strings import RES` runs the load + guards
but writes nothing (generation lives under main()); codemod_stringres.py derives its
english->id map from RES this way, so the two never drift.
"""
import os, re, html
import xml.etree.ElementTree as ET

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
TSV = os.path.join(ROOT, "scripts", "translations.tsv")
RESDIR = os.path.join(os.path.dirname(__file__), "..", "app", "src", "main", "res")
LANGS = [("ru", 1), ("ko", 2), ("ja", 3), ("zh-rCN", 4)]  # tsv col index

# id -> English source (the real user-facing literals; animation labels excluded)
RES = {
    "action_clear": "Clear",
    "action_cancel": "Cancel",
    "action_continue": "Continue",
    "action_delete": "Delete",
    "action_share": "Share",
    "action_stop": "Stop",
    "action_run": "Run",
    "action_remove": "Remove",
    "action_revoke": "Revoke",
    "action_allow": "Allow",
    "action_dont_allow": "Don't allow",
    "action_try_again": "Try again",
    "action_get_started": "Get started",
    "chat_new": "New chat",
    "chat_new_conversation": "New conversation",
    "chat_back_to_conversations": "Back to conversations",
    "chat_more_options": "More options",
    "chat_attach_file": "Attach a file",
    "chat_continue_generating": "Continue generating from where the reply stopped",
    "agent_attach_file": "Attach file",
    "agent_give_goal": "Give the agent a goal",
    "agent_allow_action_q": "Allow this action?",
    "onboarding_download_continue": "Download & continue",
    "onboarding_choose_different": "Choose a different model…",
    "onboarding_choose_smaller": "Choose a smaller model",
    "onboarding_ready": "Ready.",
    "onboarding_setup_failed": "Couldn't get set up",
    "model_change": "Change model…",
    "model_deep_thinking": "Deep thinking",
    "settings_deeper_reasoning": "Deeper reasoning",
    "settings_clear_skills": "Clear learned skills",
    "settings_privacy_policy": "Privacy Policy",
    "settings_contact_support": "Contact support",
    "settings_open_source_github": "Quenderin is open source — GitHub",
    "welcome_view_source": "View the source on GitHub",
    "consent_agree": "I understand and agree",
    "consent_read_terms": "Read the full terms",
    "badge_on_device_private": "on-device · private",
    "link_hugging_face": "Hugging Face ↗",
    # bottom navigation tabs (TSV rows: Chat / Agent / Settings)
    "tab_chat": "Chat",
    "tab_agent": "Agent",
    "tab_settings": "Settings",
    # in-conversation chat screen (empty state, composer, day divider, send/stop a11y)
    "chat_empty_title": "Ask %1$s anything",
    "chat_empty_body": "This chat runs on your phone. Its messages are processed locally.",
    "chat_composer_placeholder": "Message",   # resolves from the shared TSV "Message" row
    "chat_day_today": "Today",
    "chat_send": "Send message",
    "chat_stop": "Stop generating",
    # AI disclaimer (shown beneath chat/agent output + in Settings) + report + errors + share
    "ai_disclaimer": "Responses are AI-generated on-device and may be inaccurate or objectionable.",  # TSV
    "chat_share_conversation": "Share conversation",   # resolves from the shared TSV row
    "chat_report_response": "Report this response",
    "chat_generation_error": "Couldn't generate a reply: %1$s",
    "chat_generation_error_a11y": "Generation error: %1$s",
    # Onboarding model-fitness copy — recomposed in the UI from AndroidModelSelector / ThermalBattery /
    # MemoryFitness structured fields (numbers pre-formatted with the app locale, passed as %n$s).
    "fitness_rationale": "%1$s for your %2$s: ~%3$s tok/s on the %4$s (%5$s), using ~%6$s GB of your ~%7$s GB native-memory budget (~%8$s GB headroom).",
    "fitness_speed_comfortably": "comfortably",
    "fitness_speed_smoothly": "smoothly",
    "fitness_speed_usably": "usably",
    "fitness_chat_verdict": "Light for chat — a typical reply costs ~%1$s%% battery and barely warms the phone.",
    "fitness_sustained_verdict": "Sustained / agent use: warms and throttles ~%1$s%% slower after a few minutes, drawing ~%2$s%%/hr of continuous generation.",
    "fitness_note_over_budget": "needs ~%1$s GB, over your ~%2$s GB usable budget",
    "fitness_note_too_slow": "~%1$s tok/s on the %2$s — too slow",
    "fitness_note_ok": "~%1$s tok/s, uses ~%2$s GB",
    "model_size_download": "%1$s download",
    "memory_blocked": "Loading %1$s needs ~%2$s GB of memory — more than this device can safely spare (%3$s GB free of %4$s GB). Close other apps or choose a smaller model.",
    "memory_warning": "%1$s will leave only %2$s GB free. System may be slow.",
    "memory_safe": "%1$s fits comfortably.",
    # Model profile sheet (tap the chat header): card titles, spec labels/values, captions, blurbs
    "profile_specifications": "Specifications",
    "profile_reasoning": "Reasoning",
    "profile_privacy": "Privacy",
    "profile_technical": "Technical",
    "profile_parameters": "Parameters",
    "profile_download_size": "Download size",
    "profile_memory_needed": "Memory needed",
    "profile_quantization": "Quantization",
    "profile_precision": "Precision",
    "profile_quality": "Quality",
    "profile_format": "Format",
    "profile_file": "File",
    "profile_source": "Source",
    "profile_checksum": "Checksum",
    "profile_checksum_magic": "magic-only",
    "profile_open_source_page": "Open source page",
    "profile_params_value": "%1$sB",          # "1B" params — unit stays, number interpolated
    "profile_memory_value": "~%1$s GB RAM",
    "profile_precision_bits": "%1$s bits/weight",
    "profile_reasoning_on": "The model reasons step-by-step before answering — better on hard questions, but noticeably slower.",
    "profile_reasoning_off": "Off: fast, direct answers. Turn on to let the model reason step-by-step (slower).",
    "profile_privacy_body": "This model runs locally via llama.cpp and works offline after download. Step 5 is a separate, optional connection to your chosen CUDA host.",
    "blurb_qwen3": "Alibaba's Qwen3 — a strong, broadly multilingual all-rounder.",
    "blurb_qwen25_coder": "Qwen2.5 Coder — tuned for programming and code reasoning.",
    "blurb_deepseek_r1": "DeepSeek-R1 distilled — a reasoning-focused model that thinks before it answers.",
    "blurb_mistral": "Mistral — a fast, well-balanced general-purpose model.",
    "blurb_gemma4": "Google's Gemma 4 — the newest Gemma; excellent multilingual quality per GB.",
    "blurb_gemma3": "Google's Gemma 3 — strong multilingual coverage for its size.",
    "blurb_phi4": "Microsoft's Phi-4 Mini — efficient and capable for its footprint.",
    "blurb_llama": "Meta's Llama — a capable, general-purpose instruct model.",
    "blurb_generic": "An on-device language model running locally via llama.cpp.",
    "agent_approval_note": "Nothing runs without your yes. Dismissing counts as no.",
    "picker_model_meta": "%1$s · %2$s · needs ~%3$s GB RAM",
    # model picker fit badges + memory-shortfall note
    "fit_too_big": "Too big",
    "fit_fits": "Fits",
    "fit_tight": "Tight",
    "picker_not_enough_memory": "Not enough memory",
    "picker_memory_shortfall": "Needs ~%1$s GB to load — this phone has %2$s GB free.",
    # first-run flow: welcome page (EXTRAS: phone-baked wording; iOS twin uses %@ device word)
    "welcome_title": "Meet Quenderin",
    "welcome_tagline": "A personal AI that runs local models on your phone.",
    "welcome_private_title": "Private by design",
    "welcome_private_body": "Local conversations stay on this phone. Optional Step 5 sends text to your chosen host only with your approval.",
    "welcome_offline_title": "Works offline",
    "welcome_offline_body": "Download a model once — then it answers anywhere, airplane mode included.",
    "welcome_oss_title": "Open source",
    "welcome_oss_body": "Every line of Quenderin is public. Read it, star it, improve it.",
    # first-run flow: consent page (exact TSV rows — shared wording with iOS)
    "consent_use_judgement": "Use with judgement",
    "consent_wrong_title": "AI can be wrong",
    "consent_wrong_body": "On-device models are small. They can be confidently wrong, outdated, or occasionally inappropriate — and nothing filters them.",
    "consent_advice_title": "It is not advice",
    "consent_advice_body": "Nothing Quenderin writes is medical, legal, financial, or safety advice. Verify anything that matters with a qualified source.",
    "consent_charge_title": "You are in charge",
    "consent_charge_body": "Every answer is generated and acted on at your own risk and judgement — what you do with it is your decision alone.",
    "consent_legal": "By continuing you agree: Quenderin is provided “as is”, and to the maximum extent permitted by law, the Quenderin project and its contributors accept no liability, to anyone, under any circumstances, for the software or anything its AI models produce.",
    # first-run flow: onboarding hero + phases
    "onboarding_tagline": "An AI that runs on your phone — even offline.",
    "onboarding_private_line": "Local chat works offline. Optional Step 5 uses your chosen host with your approval.",
    "onboarding_checking": "Checking your device…",
    "onboarding_recommended_overline": "RECOMMENDED FOR YOUR DEVICE",
    "onboarding_free_up_storage": "Or free up storage and come back.",
    "onboarding_downloading": "Downloading",
    "onboarding_not_enough_space": "Not enough free space",
    # conversation list
    "chats_title": "Chats",
    "chats_empty_title": "No conversations yet",
    "chats_empty_body": "Start a chat with %1$s — it runs entirely on your phone.",
    # interpolated first-run strings
    "onboarding_size_one_time": "%1$s · one time, then it's yours offline",
    "onboarding_warming": "Warming up %1$s…",
    "onboarding_storage_needs": "This model needs ~%1$s GB — your phone has %2$s GB free.",
    "onboarding_downloading_a11y": "Downloading %1$s, %2$d percent",
    # interpolated (kept as Android format strings; args supplied at the call site)
    "agent_undo_last_move": "Undo last move (%1$d)",
    "chat_remove_named": "Remove %1$s",
    "chat_about_model": "About %1$s",
    "settings_delete_named": "Delete %1$s",
    "settings_on_device_llama": "This chat model runs on-device via llama.cpp and works offline.",
    "settings_about_on_device": "Local chat, images, and memory run on your device. Optional Step 5 sends its separate conversation to your chosen CUDA host only with your approval. No account or automatic cloud sync.",
    # Native Android entry and grouped settings.
    'action_back': 'Back',
    'tab_images': 'Images',
    'entry_welcome_body': 'Chat with local models, connect DeepSeek, or use your own computer. Choose where your messages are processed.',
    'entry_choose_title': 'Where will you chat?',
    'entry_choose_body': 'Use a model here, your DeepSeek account, or a computer you control.',
    'entry_local_title': 'On this phone',
    'entry_local_detail': 'Download once. Local messages stay on this phone and work offline. No API charge.',
    'entry_setup_local': 'Set up on this phone',
    'entry_estimated_fit': 'Estimated device fit',
    'entry_connections': 'Or connect elsewhere',
    'entry_deepseek_title': 'DeepSeek',
    'entry_deepseek_detail': 'Internet and your API key. Messages go to DeepSeek; your account is billed.',
    'entry_computer_title': 'My computer',
    'entry_computer_detail': 'Connect your paired host. Messages leave this phone; host or API costs may apply.',
    'entry_other_tools': 'More ways to use Quenderin',
    'entry_local_ready': '%1$s · active on this phone',
    'settings_responses': 'Responses',
    'settings_responses_detail': 'Speed, automatic model choice, and reasoning',
    'settings_connections': 'Connections',
    'settings_tools': 'Tools and specialist models',
    'settings_agent_detail': 'Permissions, reasoning, and recent activity',
    'settings_memory': 'Approved memories',
    'settings_memory_detail': 'Review and manage local memory',
    'settings_vision': 'Still-image questions',
    'settings_vision_detail': 'Ask about a photo with a local vision model',
    'settings_step5': 'Step 5 host',
    'settings_step5_detail': 'A separate conversation on your CUDA host',
    'settings_granite_detail': 'Configure and use this specialist model',
    'settings_app': 'App',
    'settings_storage_detail': 'Downloaded models and saved conversations',
    'settings_privacy_detail': 'Privacy policy, support, and source code',
    'settings_automatic': 'Automatic model choice',
    'settings_automatic_detail': 'Chooses among verified installed models for a new chat. Never downloads a model. Later replies keep the same model.',
    'entry_private_detail': 'Local conversations stay on this phone. Optional connections send messages only when you choose to use them.',
    # Response actions and the explicit content-report preview.
    'response_copy': 'Copy',
    'response_copied': 'Copied',
    'response_report': 'Report',
    'report_title': 'Report response',
    'report_intro': 'Review the excerpt to share with Quenderin’s developer. Your edited excerpt, reason, optional note, app version, Android platform and response source are sent with a random report ID. Google hosts this reporting service. Remove personal information you do not want to share.',
    'report_excerpt': 'Excerpt to share',
    'report_excerpt_help': 'Review and edit the excerpt before sending. Only this preview is shared.',
    'report_excerpt_truncated': 'This response is longer than the report limit. The preview contains its first 6,000 UTF-8 bytes; edit it to include the part you want reviewed.',
    'report_reason': 'Reason',
    'report_note': 'Optional note',
    'report_send': 'Send report',
    'report_sending': 'Sending…',
    'report_retry': 'Retry same report',
    'report_received': 'Report received',
    'report_receipt': 'Receipt: %1$s',
    'report_unconfirmed': 'Delivery could not be confirmed. Your draft is kept. Retry sends the same report so it can be reconciled safely.',
    'report_unavailable': 'Reporting is unavailable right now. Your draft is kept. Try again later.',
    'report_too_large': 'This report is too large. Shorten the excerpt or note.',
    'report_invalid': 'Check the excerpt and note before sending.',
    'report_conflict': 'This report could not be reconciled. Edit the preview to send it as a new report.',
    'report_close': 'Close',
    'report_reason_harassment': 'Harassment or bullying',
    'report_reason_hate': 'Hate or discrimination',
    'report_reason_sexual': 'Sexual content',
    'report_reason_violence': 'Violence or threats',
    'report_reason_dangerous': 'Dangerous activity',
    'report_reason_other': 'Other concern',
    # Bounded response presentation; Copy retains the complete response.
    'response_plain': 'Long or complex response shown as plain text. Copy includes the complete response.',
    'response_previous': 'Previous section',
    'response_next': 'Next section',
    'response_section': 'Section %1$d of %2$d',
}

# Android-only strings (or wording that differs from any iOS key) — full 4-lang set.
EXTRAS = {
    # first-run flow (phone-baked variants of the iOS %@-device rows + format-string conversions)
    "A personal AI that runs local models on your phone.":
        ("Персональный ИИ с локальными моделями на вашем телефоне.",
         "휴대폰에서 로컬 모델을 실행하는 개인 AI.",
         "スマートフォン上でローカルモデルを実行するパーソナル AI。",
         "在你的手机上运行本地模型的个人 AI。"),
    "Private by design":
        ("Приватность по умолчанию", "설계부터 프라이버시", "設計からプライバシー重視", "隐私为本"),
    "Local conversations stay on this phone. Optional Step 5 sends text to your chosen host only with your approval.":
        ("Локальные беседы остаются на этом телефоне. Необязательный Step 5 отправляет текст на выбранный вами хост только с вашего разрешения.",
         "로컬 대화는 이 휴대폰에 보관됩니다. 선택 기능인 Step 5는 사용자가 승인한 경우에만 선택한 호스트로 텍스트를 보냅니다.",
         "ローカルの会話はこのスマートフォン内に保存されます。任意の Step 5 機能は、承認した場合にのみ指定したホストへテキストを送信します。",
         "本地对话保留在这台手机上。可选的 Step 5 仅在你批准后将文本发送到你选择的主机。"),
    "Works offline":
        ("Работает офлайн", "오프라인에서 작동", "オフラインで動作", "离线可用"),
    "Download a model once — then it answers anywhere, airplane mode included.":
        ("Скачайте модель один раз — и она отвечает где угодно, даже в авиарежиме.",
         "모델을 한 번만 다운로드하면 비행기 모드에서도 어디서나 답합니다.",
         "モデルを一度ダウンロードすれば、機内モードでもどこでも答えます。",
         "模型只需下载一次——随处可答，飞行模式也不例外。"),
    "Open source":
        ("Открытый код", "오픈 소스", "オープンソース", "开源"),
    "Every line of Quenderin is public. Read it, star it, improve it.":
        ("Каждая строка Quenderin открыта. Читайте, ставьте звёзды, улучшайте.",
         "Quenderin의 모든 코드가 공개되어 있습니다. 읽고, 별을 누르고, 개선하세요.",
         "Quenderinのコードはすべて公開。読んで、スターを付けて、改善してください。",
         "Quenderin 的每一行代码都公开。欢迎阅读、加星、改进。"),
    "An AI that runs on your phone — even offline.":
        ("ИИ, который работает на вашем телефоне — даже офлайн.",
         "오프라인에서도 당신의 휴대폰에서 실행되는 AI.",
         "オフラインでもスマートフォン上で動くAI。",
         "即使离线也能在你的手机上运行的 AI。"),
    "Local chat works offline. Optional Step 5 uses your chosen host with your approval.":
        ("Локальный чат работает офлайн. Необязательный Step 5 использует выбранный вами хост с вашего разрешения.",
         "로컬 채팅은 오프라인으로 작동합니다. 선택 기능인 Step 5는 사용자가 승인하면 선택한 호스트를 사용합니다.",
         "ローカルのチャットはオフラインで使えます。任意の Step 5 機能は、承認した場合に指定したホストを使います。",
         "本地聊天可离线使用。可选的 Step 5 会在你批准后使用你选择的主机。"),
    "Or free up storage and come back.":
        ("Или освободите место и вернитесь.", "또는 저장 공간을 확보한 후 다시 시도하세요.",
         "または空き容量を確保してからもう一度。", "或者清理存储空间后再试。"),
    "Downloading":
        ("Загрузка", "다운로드 중", "ダウンロード中", "正在下载"),
    # NOTE: "Not enough free space" and "Attach a file" intentionally NOT here — they exist as
    # rows in scripts/translations.tsv (shared with iOS) and resolve from there. The dup-guard
    # below hard-fails if an EXTRAS key collides with a TSV row, so shared strings can't fork.
    "%1$s · one time, then it's yours offline":
        ("%1$s · один раз — и модель ваша, офлайн", "%1$s · 한 번만 받으면 오프라인에서 계속 사용",
         "%1$s · 一度きり、その後はオフラインで利用可能", "%1$s · 一次下载，永久离线可用"),
    "Warming up %1$s…":
        ("Прогреваем %1$s…", "%1$s 준비 중…", "%1$sをウォームアップ中…", "正在预热 %1$s…"),
    "This model needs ~%1$s GB — your phone has %2$s GB free.":
        ("Этой модели нужно ~%1$s ГБ — на вашем телефоне свободно %2$s ГБ.",
         "이 모델에는 약 %1$s GB가 필요합니다 — 휴대폰에는 %2$s GB의 여유가 있습니다.",
         "このモデルには約%1$s GBが必要です — スマートフォンの空きは%2$s GBです。",
         "此模型需要约 %1$s GB——你的手机有 %2$s GB 可用。"),
    "Downloading %1$s, %2$d percent":
        ("Загрузка %1$s, %2$d процентов", "%1$s 다운로드 중, %2$d퍼센트",
         "%1$sをダウンロード中、%2$dパーセント", "正在下载 %1$s，%2$d％"),
    "Start a chat with %1$s — it runs entirely on your phone.":
        ("Начать чат с %1$s — модель работает полностью на вашем телефоне.",
         "%1$s와 채팅을 시작하세요 — 전부 당신의 휴대폰에서 실행됩니다.",
         "%1$sとチャットを始めましょう — すべてスマートフォン上で動作します。",
         "开始与 %1$s 聊天——它完全在你的手机上运行。"),
    # in-conversation chat screen (phone-baked; iOS twin uses the %@-device TSV rows)
    "Ask %1$s anything":
        ("Спросите %1$s о чём угодно", "%1$s에게 무엇이든 물어보세요",
         "%1$sに何でも聞いてください", "向 %1$s 提问任何问题"),
    "This chat runs on your phone. Its messages are processed locally.":
        ("Этот чат работает на вашем телефоне. Сообщения обрабатываются локально.",
         "이 채팅은 휴대폰에서 실행됩니다. 메시지는 기기에서 처리됩니다.",
         "このチャットはスマートフォン上で動作します。メッセージは端末内で処理されます。",
         "此聊天在你的手机上运行，消息在本地处理。"),
    "Report this response":
        ("Пожаловаться на этот ответ", "이 응답 신고", "この応答を報告", "举报此回复"),
    "Couldn't generate a reply: %1$s":
        ("Не удалось сгенерировать ответ: %1$s", "답변을 생성하지 못했습니다: %1$s",
         "返信を生成できませんでした: %1$s", "无法生成回复：%1$s"),
    "Generation error: %1$s":
        ("Ошибка генерации: %1$s", "생성 오류: %1$s", "生成エラー: %1$s", "生成错误：%1$s"),
    # onboarding model-fitness (numbers pre-formatted with the app locale in the UI; units localized here)
    "%1$s for your %2$s: ~%3$s tok/s on the %4$s (%5$s), using ~%6$s GB of your ~%7$s GB native-memory budget (~%8$s GB headroom).":
        ("%1$s для вашего %2$s: ~%3$s ток/с на %4$s (%5$s), используя ~%6$s ГБ из ~%7$s ГБ бюджета нативной памяти (~%8$s ГБ запаса).",
         "%2$s에 맞는 %1$s: %4$s에서 ~%3$s tok/s (%5$s), 네이티브 메모리 예산 ~%7$s GB 중 ~%6$s GB 사용 (~%8$s GB 여유).",
         "%2$s向けの%1$s：%4$sで~%3$s tok/s（%5$s）、ネイティブメモリ予算~%7$s GBのうち~%6$s GBを使用（~%8$s GBの余裕）。",
         "适合你的%2$s的%1$s：在%4$s上约 %3$s tok/s（%5$s），占用原生内存预算 ~%7$s GB 中的 ~%6$s GB（~%8$s GB 余量）。"),
    "comfortably": ("с запасом", "여유롭게", "余裕をもって", "从容"),
    "smoothly":    ("плавно", "부드럽게", "スムーズに", "流畅"),
    "usably":      ("приемлемо", "쓸 만하게", "実用的に", "可用"),
    "Light for chat — a typical reply costs ~%1$s%% battery and barely warms the phone.":
        ("Лёгкая для чата — типичный ответ расходует ~%1$s%% заряда и почти не нагревает телефон.",
         "채팅에 가벼움 — 일반적인 답변은 배터리 ~%1$s%%를 사용하며 기기가 거의 발열되지 않습니다.",
         "チャットには軽量 — 一般的な返信はバッテリー約%1$s%%を消費し、ほとんど発熱しません。",
         "聊天轻量——一次典型回复约耗电 %1$s%%，几乎不发热。"),
    "Sustained / agent use: warms and throttles ~%1$s%% slower after a few minutes, drawing ~%2$s%%/hr of continuous generation.":
        ("Длительная работа / режим агента: через несколько минут нагревается и замедляется на ~%1$s%%, потребляя ~%2$s%%/час при непрерывной генерации.",
         "지속 사용 / 에이전트 모드: 몇 분 후 발열로 ~%1$s%% 느려지며, 연속 생성 시 시간당 ~%2$s%%를 소모합니다.",
         "継続使用／エージェント: 数分後に発熱で約%1$s%%遅くなり、連続生成で毎時約%2$s%%を消費します。",
         "持续使用／智能体：几分钟后因发热降速约 %1$s%%，连续生成每小时约耗电 %2$s%%。"),
    "needs ~%1$s GB, over your ~%2$s GB usable budget":
        ("нужно ~%1$s ГБ — больше вашего доступного бюджета ~%2$s ГБ",
         "~%1$s GB 필요 — 사용 가능한 예산 ~%2$s GB 초과", "~%1$s GB必要 — 使用可能な予算~%2$s GBを超過",
         "需要 ~%1$s GB，超出可用预算 ~%2$s GB"),
    "~%1$s tok/s on the %2$s — too slow":
        ("~%1$s ток/с на %2$s — слишком медленно", "%2$s에서 ~%1$s tok/s — 너무 느림",
         "%2$sで~%1$s tok/s — 遅すぎます", "在%2$s上约 %1$s tok/s——太慢"),
    "~%1$s tok/s, uses ~%2$s GB":
        ("~%1$s ток/с, использует ~%2$s ГБ", "~%1$s tok/s, ~%2$s GB 사용",
         "~%1$s tok/s、~%2$s GB使用", "约 %1$s tok/s，占用 ~%2$s GB"),
    "%1$s download":
        ("%1$s · загрузка", "%1$s 다운로드", "%1$s ダウンロード", "%1$s 下载"),
    "Loading %1$s needs ~%2$s GB of memory — more than this device can safely spare (%3$s GB free of %4$s GB). Close other apps or choose a smaller model.":
        ("Для загрузки %1$s нужно ~%2$s ГБ памяти — больше, чем это устройство может безопасно выделить (%3$s ГБ свободно из %4$s ГБ). Закройте другие приложения или выберите модель меньше.",
         "%1$s 로드에는 ~%2$s GB 메모리가 필요합니다 — 이 기기가 안전하게 확보할 수 있는 양(%4$s GB 중 %3$s GB 여유)을 초과합니다. 다른 앱을 닫거나 더 작은 모델을 선택하세요.",
         "%1$sの読み込みには~%2$s GBのメモリが必要です — この端末が安全に確保できる量（%4$s GB中%3$s GB空き）を超えます。他のアプリを閉じるか、より小さいモデルを選んでください。",
         "加载 %1$s 需要 ~%2$s GB 内存——超出本设备可安全提供的范围（%4$s GB 中 %3$s GB 可用）。请关闭其他应用或选择更小的模型。"),
    "%1$s will leave only %2$s GB free. System may be slow.":
        ("%1$s оставит свободными лишь %2$s ГБ. Система может работать медленно.",
         "%1$s를 사용하면 %2$s GB만 남습니다. 시스템이 느려질 수 있습니다.",
         "%1$sを使うと空きは%2$s GBだけになります。システムが遅くなる場合があります。",
         "%1$s 将只剩 %2$s GB 可用。系统可能变慢。"),
    "%1$s fits comfortably.":
        ("%1$s помещается с запасом.", "%1$s는 여유롭게 실행됩니다.", "%1$sは余裕をもって動作します。", "%1$s 运行从容。"),
    # model profile sheet
    "Specifications": ("Характеристики", "사양", "仕様", "规格"),
    "Technical":      ("Технические данные", "기술 정보", "技術情報", "技术信息"),
    "Parameters":     ("Параметры", "매개변수", "パラメータ", "参数"),
    "Download size":  ("Размер загрузки", "다운로드 크기", "ダウンロードサイズ", "下载大小"),
    "Memory needed":  ("Нужно памяти", "필요 메모리", "必要メモリ", "所需内存"),
    "Quantization":   ("Квантизация", "양자화", "量子化", "量化"),
    "Precision":      ("Точность", "정밀도", "精度", "精度"),
    "Format":         ("Формат", "형식", "形式", "格式"),
    "File":           ("Файл", "파일", "ファイル", "文件"),
    "Checksum":       ("Контрольная сумма", "체크섬", "チェックサム", "校验和"),
    "magic-only":     ("только сигнатура", "매직만", "マジックのみ", "仅魔数"),
    "%1$sB":          ("%1$s млрд", "%1$sB", "%1$sB", "%1$sB"),
    "~%1$s GB RAM":   ("~%1$s ГБ ОЗУ", "~%1$s GB RAM", "~%1$s GB RAM", "~%1$s GB 内存"),
    "%1$s bits/weight": ("%1$s бит/вес", "%1$s 비트/가중치", "%1$s ビット/重み", "%1$s 位/权重"),
    "The model reasons step-by-step before answering — better on hard questions, but noticeably slower.":
        ("Модель рассуждает шаг за шагом перед ответом — лучше на сложных вопросах, но заметно медленнее.",
         "모델이 답하기 전에 단계별로 추론합니다 — 어려운 질문에 더 좋지만 눈에 띄게 느립니다.",
         "モデルは答える前に段階的に推論します — 難しい質問には有利ですが、明らかに遅くなります。",
         "模型在回答前逐步推理——难题上更好，但明显更慢。"),
    "Off: fast, direct answers. Turn on to let the model reason step-by-step (slower).":
        ("Выключено: быстрые прямые ответы. Включите, чтобы модель рассуждала шаг за шагом (медленнее).",
         "꺼짐: 빠르고 직접적인 답변. 켜면 모델이 단계별로 추론합니다(더 느림).",
         "オフ: 速く直接的な回答。オンにするとモデルが段階的に推論します（遅くなります）。",
         "关闭：快速、直接的回答。开启后模型会逐步推理（更慢）。"),
    "Alibaba's Qwen3 — a strong, broadly multilingual all-rounder.":
        ("Qwen3 от Alibaba — сильная, широко многоязычная универсальная модель.",
         "Alibaba의 Qwen3 — 강력하고 폭넓게 다국어를 지원하는 올라운더.",
         "AlibabaのQwen3 — 強力で幅広い多言語対応のオールラウンダー。",
         "阿里巴巴的 Qwen3——强大、广泛多语言的全能选手。"),
    "Qwen2.5 Coder — tuned for programming and code reasoning.":
        ("Qwen2.5 Coder — заточен под программирование и работу с кодом.",
         "Qwen2.5 Coder — 프로그래밍과 코드 추론에 맞춰 조정됨.",
         "Qwen2.5 Coder — プログラミングとコード推論に最適化。",
         "Qwen2.5 Coder——专为编程和代码推理调优。"),
    "DeepSeek-R1 distilled — a reasoning-focused model that thinks before it answers.":
        ("DeepSeek-R1 (дистиллят) — модель с упором на рассуждение, думает перед ответом.",
         "DeepSeek-R1 증류 — 답하기 전에 생각하는 추론 중심 모델.",
         "DeepSeek-R1 蒸留 — 答える前に考える推論重視のモデル。",
         "DeepSeek-R1 蒸馏版——注重推理、先思考再回答。"),
    "Mistral — a fast, well-balanced general-purpose model.":
        ("Mistral — быстрая, хорошо сбалансированная универсальная модель.",
         "Mistral — 빠르고 균형 잡힌 범용 모델.",
         "Mistral — 高速でバランスの取れた汎用モデル。",
         "Mistral——快速、均衡的通用模型。"),
    "Google's Gemma 4 — the newest Gemma; excellent multilingual quality per GB.":
        ("Gemma 4 от Google — новейшая Gemma; отличное многоязычное качество на гигабайт.",
         "Google의 Gemma 4 — 최신 Gemma; GB당 뛰어난 다국어 품질.",
         "GoogleのGemma 4 — 最新のGemma。GBあたりの多言語品質が優秀。",
         "谷歌的 Gemma 4——最新 Gemma；每 GB 多语言质量出色。"),
    "Google's Gemma 3 — strong multilingual coverage for its size.":
        ("Gemma 3 от Google — сильное многоязычие для своего размера.",
         "Google의 Gemma 3 — 크기 대비 강력한 다국어 지원.",
         "GoogleのGemma 3 — サイズの割に強力な多言語対応。",
         "谷歌的 Gemma 3——以其体量而言多语言覆盖强。"),
    "Microsoft's Phi-4 Mini — efficient and capable for its footprint.":
        ("Phi-4 Mini от Microsoft — эффективная и способная для своего размера.",
         "Microsoft의 Phi-4 Mini — 크기 대비 효율적이고 유능함.",
         "MicrosoftのPhi-4 Mini — サイズの割に効率的で高性能。",
         "微软的 Phi-4 Mini——以其体量而言高效且能干。"),
    "Meta's Llama — a capable, general-purpose instruct model.":
        ("Llama от Meta — способная универсальная instruct-модель.",
         "Meta의 Llama — 유능한 범용 instruct 모델.",
         "MetaのLlama — 有能な汎用instructモデル。",
         "Meta 的 Llama——能干的通用指令模型。"),
    "An on-device language model running locally via llama.cpp.":
        ("Локальная языковая модель, работающая на устройстве через llama.cpp.",
         "llama.cpp를 통해 로컬에서 실행되는 온디바이스 언어 모델.",
         "llama.cpp によりローカルで動作するオンデバイス言語モデル。",
         "通过 llama.cpp 在本地运行的设备端语言模型。"),
    "Nothing runs without your yes. Dismissing counts as no.":
        ("Ничто не запускается без вашего «да». Закрытие считается отказом.",
         "당신의 승인 없이는 아무것도 실행되지 않습니다. 닫으면 거부로 간주됩니다.",
         "あなたの「はい」なしには何も実行されません。閉じると「いいえ」とみなされます。",
         "未经你同意，任何操作都不会执行。关闭视为拒绝。"),
    "%1$s · %2$s · needs ~%3$s GB RAM":
        ("%1$s · %2$s · нужно ~%3$s ГБ ОЗУ", "%1$s · %2$s · ~%3$s GB RAM 필요",
         "%1$s · %2$s · ~%3$s GB RAM必要", "%1$s · %2$s · 需要 ~%3$s GB 内存"),
    "Too big":  ("Слишком большая", "너무 큼", "大きすぎ", "太大"),
    "Fits":     ("Подходит", "적합", "適合", "合适"),
    "Tight":    ("Впритык", "빠듯함", "ぎりぎり", "紧张"),
    "Needs ~%1$s GB to load — this phone has %2$s GB free.":
        ("Для загрузки нужно ~%1$s ГБ — на телефоне свободно %2$s ГБ.",
         "로드하려면 ~%1$s GB 필요 — 이 휴대폰은 %2$s GB 여유.",
         "読み込みに~%1$s GB必要 — この端末の空きは%2$s GB。",
         "加载需要 ~%1$s GB——本手机剩余 %2$s GB。"),
    "Try again":        ("Повторить", "다시 시도", "再試行", "重试"),
    "Get started":      ("Начать", "시작하기", "始める", "开始"),
    "New conversation": ("Новая беседа", "새 대화", "新しい会話", "新对话"),
    "Back to conversations": ("Назад к беседам", "대화 목록으로", "会話一覧に戻る", "返回对话列表"),
    "More options":     ("Ещё", "더 보기", "その他", "更多选项"),
    "Attach file":      ("Прикрепить файл", "파일 첨부", "ファイルを添付", "附加文件"),
    "Allow this action?": ("Разрешить это действие?", "이 동작을 허용할까요?", "この操作を許可しますか？", "允许此操作？"),
    "Allow":            ("Разрешить", "허용", "許可", "允许"),
    "Ready.":           ("Готово.", "준비됨.", "準備完了。", "已就绪。"),
    "Deep thinking":    ("Глубокое размышление", "심층 사고", "深い思考", "深度思考"),
    "Clear learned skills": ("Очистить выученные навыки", "학습된 스킬 지우기", "学習したスキルを消去", "清除已学技能"),
    "Quenderin is open source — GitHub": ("Quenderin — открытый код: GitHub", "Quenderin은 오픈소스입니다 — GitHub", "Quenderinはオープンソース — GitHub", "Quenderin 是开源的——GitHub"),
    "Hugging Face ↗":   ("Hugging Face ↗", "Hugging Face ↗", "Hugging Face ↗", "Hugging Face ↗"),
    "Undo last move (%1$d)": ("Отменить последнее перемещение (%1$d)", "마지막 이동 취소 (%1$d)", "直前の移動を取り消す（%1$d）", "撤销上一次移动（%1$d）"),
    "Remove %1$s":      ("Убрать %1$s", "%1$s 제거", "%1$sを削除", "移除 %1$s"),
    "About %1$s":       ("О модели %1$s", "%1$s 정보", "%1$sについて", "关于 %1$s"),
    "Delete %1$s":      ("Удалить %1$s", "%1$s 삭제", "%1$sを削除", "删除 %1$s"),
    "Remove":           ("Убрать", "제거", "削除", "移除"),
    "Revoke":           ("Отозвать", "취소", "取り消す", "撤销"),
    "Run":              ("Запустить", "실행", "実行", "运行"),
    "Share":            ("Поделиться", "공유", "共有", "分享"),
    # Native Android entry and grouped settings. Shared TSV rows still resolve from TSV.
    'Back': ('Назад', '뒤로', '戻る', '返回'),
    'Images': ('Изображения', '이미지', '画像', '图像'),
    'Chat with local models, connect DeepSeek, or use your own computer. Choose where your messages are processed.': ('Общайтесь с локальными моделями, подключите DeepSeek или свой компьютер. Выберите, где обрабатываются ваши сообщения.', '로컬 모델, DeepSeek 또는 내 컴퓨터로 대화하세요. 메시지를 처리할 위치를 선택합니다.', 'ローカルモデル、DeepSeek、自分のパソコンでチャット。メッセージを処理する場所を選べます。', '使用本地模型、连接 DeepSeek，或使用自己的电脑。选择消息的处理位置。'),
    'Where will you chat?': ('Где будем общаться?', '어디서 대화할까요?', 'どこでチャットしますか？', '在哪里聊天？'),
    'Use a model here, your DeepSeek account, or a computer you control.': ('Используйте модель здесь, свой аккаунт DeepSeek или свой компьютер.', '이 기기의 모델, 내 DeepSeek 계정 또는 직접 관리하는 컴퓨터를 사용하세요.', 'この端末のモデル、DeepSeekアカウント、または自分で管理するパソコンを使えます。', '使用此设备上的模型、自己的 DeepSeek 账户，或自己控制的电脑。'),
    'On this phone': ('На этом телефоне', '이 휴대폰에서', 'このスマートフォン', '在此手机上'),
    'Download once. Local messages stay on this phone and work offline. No API charge.': ('Скачайте один раз. Локальные сообщения остаются на телефоне, работают офлайн. Без платы за API.', '한 번 다운로드하면 오프라인에서도 사용합니다. 로컬 메시지는 이 휴대폰에 남으며 API 요금은 없습니다.', '一度ダウンロードすればオフラインで使えます。ローカルのメッセージは端末内に保存され、API料金はかかりません。', '下载一次即可离线使用。本地消息保留在此手机上，无 API 费用。'),
    'Set up on this phone': ('Настроить на телефоне', '이 휴대폰에 설정', 'この端末で設定', '在此手机上设置'),
    'Estimated device fit': ('Оценка совместимости', '기기 적합도 추정', '端末との適合性の推定', '设备适配估计'),
    'Or connect elsewhere': ('Или подключитесь удалённо', '다른 곳에 연결', '外部に接続する', '或连接其他位置'),
    'DeepSeek': ('DeepSeek', 'DeepSeek', 'DeepSeek', 'DeepSeek'),
    'Internet and your API key. Messages go to DeepSeek; your account is billed.': ('Нужны интернет и ваш API-ключ. Сообщения уходят в DeepSeek; оплата с вашего аккаунта.', '인터넷과 내 API 키가 필요합니다. 메시지가 DeepSeek로 전송되며 내 계정에 요금이 청구됩니다.', 'インターネットとAPIキーが必要です。メッセージはDeepSeekへ送られ、利用料金は自分のアカウントに請求されます。', '需要联网及自己的 API 密钥。消息发送至 DeepSeek，费用由你的账户承担。'),
    'My computer': ('Мой компьютер', '내 컴퓨터', '自分のパソコン', '我的电脑'),
    'Connect your paired host. Messages leave this phone; host or API costs may apply.': ('Подключите сопряжённый хост. Сообщения покидают телефон; возможна плата за хост или API.', '페어링한 호스트에 연결합니다. 메시지가 휴대폰 밖으로 전송되며 호스트나 API 요금이 발생할 수 있습니다.', 'ペアリングしたホストに接続します。メッセージは端末外に送られ、ホストやAPIの費用が発生する場合があります。', '连接已配对的主机。消息会离开此手机，可能产生主机或 API 费用。'),
    'More ways to use Quenderin': ('Другие возможности Quenderin', 'Quenderin의 다른 기능', 'Quenderinのその他の使い方', 'Quenderin 的更多用法'),
    '%1$s · active on this phone': ('%1$s · активно на телефоне', '%1$s · 이 휴대폰에서 활성화됨', '%1$s · この端末で有効', '%1$s · 已在此手机上启用'),
    'Responses': ('Ответы', '응답', '応答', '回答'),
    'Speed, automatic model choice, and reasoning': ('Скорость, автовыбор модели и рассуждение', '속도, 자동 모델 선택 및 추론', '速度、自動モデル選択、推論', '速度、自动模型选择与推理'),
    'Connections': ('Подключения', '연결', '接続', '连接'),
    'Tools and specialist models': ('Инструменты и специальные модели', '도구 및 전문 모델', 'ツールと専用モデル', '工具与专用模型'),
    'Permissions, reasoning, and recent activity': ('Разрешения, рассуждение и недавние действия', '권한, 추론 및 최근 활동', '権限、推論、最近のアクティビティ', '权限、推理与近期活动'),
    'Approved memories': ('Одобренные воспоминания', '승인한 메모리', '承認済みの記憶', '已批准的记忆'),
    'Review and manage local memory': ('Просмотр и управление локальной памятью', '로컬 메모리 확인 및 관리', 'ローカルの記憶を確認・管理', '查看和管理本地记忆'),
    'Still-image questions': ('Вопросы по изображениям', '사진에 관한 질문', '静止画への質問', '静态图像问答'),
    'Ask about a photo with a local vision model': ('Задайте вопрос о фото локальной модели', '로컬 비전 모델에 사진 질문하기', 'ローカルの画像モデルに写真について質問', '使用本地视觉模型询问照片'),
    'Step 5 host': ('Хост Step 5', 'Step 5 호스트', 'Step 5ホスト', 'Step 5 主机'),
    'A separate conversation on your CUDA host': ('Отдельная беседа на вашем CUDA-хосте', '내 CUDA 호스트에서 별도 대화', '自分のCUDAホスト上の独立した会話', '在自己的 CUDA 主机上进行独立对话'),
    'Configure and use this specialist model': ('Настройка и использование специальной модели', '전문 모델 설정 및 사용', '専用モデルを設定・使用', '配置和使用此专用模型'),
    'App': ('Приложение', '앱', 'アプリ', '应用'),
    'Downloaded models and saved conversations': ('Скачанные модели и сохранённые беседы', '다운로드한 모델 및 저장된 대화', 'ダウンロード済みモデルと保存した会話', '已下载模型与已保存对话'),
    'Privacy policy, support, and source code': ('Политика конфиденциальности, поддержка и код', '개인정보 처리방침, 지원 및 소스 코드', 'プライバシーポリシー、サポート、ソースコード', '隐私政策、支持与源代码'),
    'Automatic model choice': ('Автоматический выбор модели', '자동 모델 선택', 'モデルを自動選択', '自动选择模型'),
    'Chooses among verified installed models for a new chat. Never downloads a model. Later replies keep the same model.': ('Выбирает проверенную установленную модель для нового чата. Ничего не скачивает. Следующие ответы используют ту же модель.', '새 대화에서 검증된 설치 모델 중 선택합니다. 모델을 다운로드하지 않으며 이후 응답도 같은 모델을 사용합니다.', '新しいチャットに検証済みのインストール済みモデルを選びます。モデルはダウンロードしません。以降の返信にも同じモデルを使います。', '为新对话从已验证且已安装的模型中选择。绝不下载模型，后续回答继续使用同一模型。'),
    'Local conversations stay on this phone. Optional connections send messages only when you choose to use them.': ('Локальные беседы остаются на телефоне. Внешние подключения передают сообщения, только когда вы решите их использовать.', '로컬 대화는 이 휴대폰에 남습니다. 외부 연결은 사용자가 사용하기로 선택했을 때만 메시지를 전송합니다.', 'ローカルの会話はこの端末に残ります。外部接続は、使うことを選んだ場合にのみメッセージを送信します。', '本地对话保留在此手机上。可选连接仅在你选择使用时发送消息。'),
    # Response actions and the explicit content-report preview.
    'Copied': ('Скопировано', '복사됨', 'コピーしました', '已复制'),
    'Report': ('Пожаловаться', '신고', '報告', '举报'),
    'Review the excerpt to share with Quenderin’s developer. Your edited excerpt, reason, optional note, app version, Android platform and response source are sent with a random report ID. Google hosts this reporting service. Remove personal information you do not want to share.': ('Проверьте отрывок для отправки разработчику Quenderin. Отредактированный отрывок, причина, необязательное примечание, версия приложения, платформа Android и источник ответа отправляются со случайным идентификатором жалобы. Сервис размещён у Google. Удалите личные сведения, которыми не хотите делиться.', 'Quenderin 개발자에게 보낼 발췌문을 검토하세요. 수정한 발췌문, 신고 사유, 선택적 메모, 앱 버전, Android 플랫폼 및 응답 출처가 무작위 신고 ID와 함께 전송됩니다. 이 신고 서비스는 Google에서 호스팅합니다. 공유하고 싶지 않은 개인정보는 삭제하세요.', 'Quenderinの開発者と共有する抜粋を確認してください。編集した抜粋、理由、任意のメモ、アプリのバージョン、Androidプラットフォーム、応答元がランダムな報告IDとともに送信されます。この報告サービスはGoogleでホストされています。共有したくない個人情報は削除してください。', '请检查要与 Quenderin 开发者分享的摘录。你编辑后的摘录、原因、可选备注、应用版本、Android 平台及回答来源将随随机举报 ID 一起发送。此举报服务由 Google 托管。请删除不想分享的个人信息。'),
    'Excerpt to share': ('Отрывок для отправки', '공유할 발췌문', '共有する抜粋', '要分享的摘录'),
    'Review and edit the excerpt before sending. Only this preview is shared.': ('Перед отправкой проверьте и отредактируйте отрывок. Отправляется только этот текст.', '전송 전에 발췌문을 검토하고 수정하세요. 이 미리보기만 공유됩니다.', '送信前に抜粋を確認・編集してください。このプレビューだけが共有されます。', '发送前请检查并编辑摘录。仅分享此预览内容。'),
    'This response is longer than the report limit. The preview contains its first 6,000 UTF-8 bytes; edit it to include the part you want reviewed.': ('Ответ превышает лимит жалобы. В предпросмотре — первые 6 000 байт UTF-8; отредактируйте текст, включив нужную для проверки часть.', '이 응답은 신고 한도를 초과합니다. 미리보기에는 처음 6,000 UTF-8 바이트가 포함됩니다. 검토받고 싶은 부분이 포함되도록 수정하세요.', 'この応答は報告の上限を超えています。プレビューには最初の6,000 UTF-8バイトが含まれます。確認してほしい部分が入るように編集してください。', '此回答超过举报长度限制。预览包含前 6,000 个 UTF-8 字节；请编辑以包含你希望审核的部分。'),
    'Reason': ('Причина', '사유', '理由', '原因'),
    'Optional note': ('Примечание (необязательно)', '메모 (선택)', 'メモ（任意）', '备注（可选）'),
    'Send report': ('Отправить жалобу', '신고 보내기', '報告を送信', '发送举报'),
    'Sending…': ('Отправка…', '전송 중…', '送信中…', '发送中…'),
    'Retry same report': ('Повторить ту же жалобу', '같은 신고 다시 보내기', '同じ報告を再送', '重试同一举报'),
    'Report received': ('Жалоба получена', '신고 접수됨', '報告を受信しました', '举报已收到'),
    'Receipt: %1$s': ('Подтверждение: %1$s', '접수 번호: %1$s', '受付番号: %1$s', '回执：%1$s'),
    'Delivery could not be confirmed. Your draft is kept. Retry sends the same report so it can be reconciled safely.': ('Не удалось подтвердить доставку. Черновик сохранён. Повторно отправляется та же жалоба для безопасной сверки.', '전송을 확인할 수 없습니다. 초안은 유지됩니다. 다시 시도하면 같은 신고를 보내 안전하게 처리 여부를 확인합니다.', '送信を確認できませんでした。下書きは保持されています。再試行では同じ報告を送り、安全に照合できるようにします。', '无法确认送达。草稿已保留。重试将发送同一举报，以便安全核对。'),
    'Reporting is unavailable right now. Your draft is kept. Try again later.': ('Сейчас отправка жалоб недоступна. Черновик сохранён. Попробуйте позже.', '지금은 신고할 수 없습니다. 초안은 유지됩니다. 나중에 다시 시도하세요.', '現在、報告サービスを利用できません。下書きは保持されています。後でもう一度お試しください。', '举报服务暂不可用。草稿已保留，请稍后重试。'),
    'This report is too large. Shorten the excerpt or note.': ('Жалоба слишком большая. Сократите отрывок или примечание.', '신고 내용이 너무 큽니다. 발췌문이나 메모를 줄이세요.', '報告が長すぎます。抜粋やメモを短くしてください。', '举报内容过长，请缩短摘录或备注。'),
    'Check the excerpt and note before sending.': ('Проверьте отрывок и примечание перед отправкой.', '전송 전에 발췌문과 메모를 확인하세요.', '送信前に抜粋とメモを確認してください。', '发送前请检查摘录和备注。'),
    'This report could not be reconciled. Edit the preview to send it as a new report.': ('Не удалось сверить эту жалобу. Измените текст, чтобы отправить её как новую.', '이 신고의 처리 여부를 확인하지 못했습니다. 미리보기를 수정하여 새 신고로 보내세요.', 'この報告を照合できませんでした。プレビューを編集して新しい報告として送信してください。', '无法核对此举报。请编辑预览内容，将其作为新举报发送。'),
    'Close': ('Закрыть', '닫기', '閉じる', '关闭'),
    'Harassment or bullying': ('Домогательства или травля', '괴롭힘 또는 따돌림', '嫌がらせ・いじめ', '骚扰或欺凌'),
    'Hate or discrimination': ('Ненависть или дискриминация', '혐오 또는 차별', '憎悪・差別', '仇恨或歧视'),
    'Sexual content': ('Сексуальный контент', '성적 콘텐츠', '性的な内容', '色情内容'),
    'Violence or threats': ('Насилие или угрозы', '폭력 또는 위협', '暴力・脅迫', '暴力或威胁'),
    'Dangerous activity': ('Опасные действия', '위험한 활동', '危険な行為', '危险活动'),
    'Other concern': ('Другая проблема', '기타 문제', 'その他の問題', '其他问题'),
    # Bounded response presentation.
    'Long or complex response shown as plain text. Copy includes the complete response.': ('Длинный или сложный ответ показан обычным текстом. Копирование включает весь ответ.', '길거나 복잡한 응답을 일반 텍스트로 표시합니다. 복사하면 전체 응답이 포함됩니다.', '長い応答や複雑な応答はプレーンテキストで表示します。コピーには応答全体が含まれます。', '较长或复杂的回答以纯文本显示。复制将包含完整回答。'),
    'Previous section': ('Предыдущая часть', '이전 부분', '前のセクション', '上一部分'),
    'Next section': ('Следующая часть', '다음 부분', '次のセクション', '下一部分'),
    'Section %1$d of %2$d': ('Часть %1$d из %2$d', '%2$d개 중 %1$d번째 부분', '%2$dセクション中%1$d', '第 %1$d 部分，共 %2$d 部分'),
}

# load TSV (english -> [ru,ko,ja,zh])
tsv = {}
for line in open(TSV, encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    c = line.rstrip("\n").split("\t")
    if len(c) == 5:
        tsv[c[0]] = c[1:]

# GUARD: the TSV is the single source of truth for any string shared with iOS. An EXTRAS key that
# ALSO names a TSV row would silently fork one platform's wording from the other — so hard-fail here
# and make the author delete the EXTRAS copy (it resolves from the TSV) or give it distinct English.
_dupes = sorted(set(EXTRAS) & set(tsv))
if _dupes:
    raise SystemExit(
        "gen_strings: EXTRAS keys shadow shared TSV rows — delete them (they resolve from the TSV):\n  "
        + "\n  ".join(map(repr, _dupes)))

_POSITIONAL = re.compile(r'%\d+\$[a-zA-Z]')  # Android positional format specifier, e.g. %1$s / %2$d

def _check_percent(rid, lang, val):
    # A literal ASCII '%' that is neither an escaped '%%' nor part of a positional specifier is a
    # trap: Resources.getString(id, args) always runs String.format, and a stray '%' throws
    # UnknownFormatConversionException in exactly the one locale carrying it. Catch it at BUILD time.
    residue = _POSITIONAL.sub("", val.replace("%%", ""))
    if "%" in residue:
        raise SystemExit(
            f"gen_strings: bare '%' in {rid} [{lang}]: {val!r}\n"
            "  escape a literal percent as '%%', or use a positional '%1$s'-style specifier.")

def esc(s):
    # Backslash FIRST (order matters — the apostrophe/quote rules below add their own backslashes),
    # then XML-escape, then the Android apostrophe/quote escaping.
    s = s.replace("\\", "\\\\")
    s = html.escape(s, quote=False)
    return s.replace("'", "\\'").replace('"', '\\"')

def translations_for(en):
    # TSV (shared with iOS) wins over EXTRAS — matches the docstring contract, and the _dupes guard
    # guarantees the two never disagree for the same English key anyway.
    if en in tsv:
        return dict(zip(("ru", "ko", "ja", "zh-rCN"), tsv[en]))
    if en in EXTRAS:
        return dict(zip(("ru", "ko", "ja", "zh-rCN"), EXTRAS[en]))
    return None

def write_xml(path, pairs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lang = os.path.basename(os.path.dirname(path)).replace("values-", "") or "en"
    generated = {}
    for rid, val in pairs:
        _check_percent(rid, lang, val)
        # formatted="false" only for display strings with NO positional args (suppresses aapt's
        # lone-percent lint); positional strings stay formatted (the default) so args validate.
        fmt = ' formatted="false"' if (not _POSITIONAL.search(val) and "%" in val) else ""
        generated[rid] = f'<string name="{rid}"{fmt}>{esc(val)}</string>'
    try:
        with open(path, encoding="utf-8") as source:
            existing = source.read()
    except FileNotFoundError:
        existing = None
    if existing is None:
        out = ['<?xml version="1.0" encoding="utf-8"?>', "<resources>"]
        out.extend("    " + node for node in generated.values())
        out.append("</resources>\n")
        content = "\n".join(out)
    else:
        # Later app strings also live in these files. Update only the named rows this
        # generator owns, preserving other resources, comments and formatting exactly.
        if ET.fromstring(existing).tag != "resources":
            raise SystemExit(f"gen_strings: expected a resources document: {path}")
        seen = set()
        def replace_node(match):
            node = match.group(0)
            if node.startswith("<!--"):
                return node
            name = re.search(r"""\sname\s*=\s*(["'])(.*?)\1""", node.split(">", 1)[0])
            rid = name.group(2) if name else None
            if rid not in generated:
                return node
            if rid in seen:
                raise SystemExit(f"gen_strings: duplicate managed resource {rid}: {path}")
            seen.add(rid)
            return generated[rid]
        content = re.sub(r"<!--.*?-->|<string(?=\s|>)[^>]*?(?:/\s*>|>.*?</string\s*>)",
                         replace_node, existing, flags=re.DOTALL)
        missing = [node for rid, node in generated.items() if rid not in seen]
        if missing:
            closing = re.search(r"</resources\s*>", content)
            if closing is None:
                raise SystemExit(f"gen_strings: cannot append rows without a resources closing tag: {path}")
            content = (content[:closing.start()] + "".join("    " + node + "\n" for node in missing)
                       + content[closing.start():])
    ET.fromstring(content)  # Reject invalid output before touching the existing file.
    with open(path, "w", encoding="utf-8") as destination:
        destination.write(content)

def _bcp47(qualifier):
    # Android resource qualifier -> BCP-47 for <locale-config>: "zh-rCN" -> "zh-CN".
    return qualifier.replace("-r", "-")

def write_locales_config():
    # Generated from LANGS (+ en) so the per-app language picker can NEVER drift from the resource
    # locales actually shipped — add a column to LANGS and this file updates in the same run.
    path = os.path.join(RESDIR, "xml", "locales_config.xml")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    locales = ["en"] + [_bcp47(l) for l, _ in LANGS]
    out = ['<?xml version="1.0" encoding="utf-8"?>',
           '<!-- GENERATED by tools/gen_strings.py from LANGS — do not hand-edit. -->',
           '<locale-config xmlns:android="http://schemas.android.com/apk/res/android">']
    out += [f'    <locale android:name="{loc}"/>' for loc in locales]
    out += ['</locale-config>', '']
    open(path, "w", encoding="utf-8").write("\n".join(out))

def main():
    # English base
    write_xml(os.path.join(RESDIR, "values", "strings.xml"), list(RES.items()))

    missing = []
    for lang, idx in LANGS:
        pairs = []
        for rid, en in RES.items():
            t = translations_for(en)
            if t is None:
                missing.append(en); continue
            pairs.append((rid, t[lang]))
        write_xml(os.path.join(RESDIR, f"values-{lang}", "strings.xml"), pairs)

    write_locales_config()

    if missing:
        print("MISSING translations (add to EXTRAS):")
        for m in sorted(set(missing)):
            print("   ", repr(m))
    else:
        print(f"updated {len(RES)} managed strings in en + {len(LANGS)} locales (+ locales_config.xml)")

if __name__ == "__main__":
    main()
