#!/usr/bin/env python3
"""Chunk 2/3: fill ko/ja/zh-Hans columns (keys H–S)."""
import os

T = {
 "HOW IT WORKS": ("작동 방식", "仕組み", "工作原理"),
 "Hugging Face": ("Hugging Face", "Hugging Face", "Hugging Face"),
 "I understand and agree": ("이해했으며 동의합니다", "理解して同意します", "我已了解并同意"),
 "Import": ("가져오기", "読み込む", "导入"),
 "Install": ("설치", "インストール", "安装"),
 "Install %@": ("%@ 설치", "%@をインストール", "安装 %@"),
 "Installed models, the curated catalog, and open GGUFs — flexible for beginners and power users.":
   ("설치된 모델, 엄선된 카탈로그, 공개 GGUF — 초보자와 고급 사용자 모두에게 유연합니다.",
    "インストール済みモデル、厳選カタログ、公開GGUF — 初心者にも上級者にも柔軟に対応。",
    "已安装的模型、精选目录和开放 GGUF——新手和高级用户都适用。"),
 "Installed — tap Use to switch to that model.":
   ("설치됨 — 사용을 눌러 해당 모델로 전환하세요.", "インストール済み — 「使う」でそのモデルに切り替え。", "已安装——点按使用切换到该模型。"),
 "It opens apps, clicks, types, and works the tools for you — all on your machine.":
   ("앱을 열고, 클릭하고, 입력하고, 도구를 다뤄 줍니다 — 전부 당신의 컴퓨터에서.",
    "アプリを開き、クリックし、入力し、ツールを操作します — すべてあなたのマシン上で。",
    "它替你打开应用、点击、输入、使用工具——全部在你的电脑上。"),
 "It uses on-device tools to plan and get it done — privately, on your iPhone.":
   ("기기 내 도구로 계획을 세우고 실행합니다 — 당신의 iPhone에서, 프라이빗하게.",
    "オンデバイスのツールで計画し、やり遂げます — あなたのiPhone上で、プライベートに。",
    "它使用设备端工具进行规划并完成任务——私密地，在你的 iPhone 上。"),
 "Jump to latest": ("최신으로 이동", "最新へ移動", "跳到最新"),
 "Jump to the latest message": ("최신 메시지로 이동", "最新のメッセージへ移動", "跳到最新消息"),
 "License": ("라이선스", "ライセンス", "许可证"),
 "Loading downloadable files…": ("다운로드 가능한 파일 불러오는 중…", "ダウンロード可能なファイルを読み込み中…", "正在载入可下载文件…"),
 "Meet Quenderin": ("Quenderin을 만나보세요", "Quenderinへようこそ", "认识 Quenderin"),
 "Memory fit: %@": ("메모리 적합도: %@", "メモリ適合: %@", "内存适配：%@"),
 "Message": ("메시지", "メッセージ", "消息"),
 "Message bubbles": ("말풍선", "吹き出し", "消息气泡"),
 "Model": ("모델", "モデル", "模型"),
 "Model card, license, discussions on huggingface.co":
   ("huggingface.co의 모델 카드, 라이선스, 토론", "huggingface.coのモデルカード・ライセンス・ディスカッション", "huggingface.co 上的模型卡、许可与讨论"),
 "Model library": ("모델 라이브러리", "モデルライブラリ", "模型库"),
 "Models": ("모델", "モデル", "模型"),
 "NEEDS YOUR OK IN SETTINGS → AGENT": ("설정 → 에이전트에서 승인 필요", "設定 → エージェントで許可が必要", "需在设置 → 智能体中授权"),
 "New Chat": ("새 채팅", "新しいチャット", "新对话"),
 "New chat": ("새 채팅", "新しいチャット", "新对话"),
 "New chat (⌘N)": ("새 채팅 (⌘N)", "新しいチャット (⌘N)", "新对话 (⌘N)"),
 "New chats get a one-tap suggestion — coding, reasoning, languages — from what's installed.":
   ("새 채팅마다 설치된 모델 중에서 한 번의 탭으로 제안을 받습니다 — 코딩·추론·언어별로.",
    "新しいチャットでは、インストール済みモデルからワンタップ提案が届きます — コーディング・推論・言語別に。",
    "新对话会根据已安装的模型获得一键建议——编程、推理、多语言。"),
 "No account, no log-out — your chats never leave this Mac.":
   ("계정도 로그아웃도 없습니다 — 채팅은 이 Mac을 떠나지 않습니다.",
    "アカウントもログアウトもなし — チャットがこのMacを離れることはありません。",
    "无账号、无需退出——你的聊天永远不会离开这台 Mac。"),
 "No chats yet": ("아직 채팅이 없습니다", "まだチャットはありません", "还没有聊天"),
 "No conversations yet": ("아직 대화가 없습니다", "まだ会話はありません", "还没有对话"),
 "No files match your filters for this model. Clear quant/size filters or turn off “Fits only”.":
   ("이 모델에 대해 필터와 일치하는 파일이 없습니다. 양자화/크기 필터를 지우거나 “맞는 것만”을 끄세요.",
    "このモデルにはフィルタに合うファイルがありません。量子化/サイズのフィルタを解除するか、「適合のみ」をオフにしてください。",
    "没有符合筛选条件的文件。请清除量化/大小筛选，或关闭“仅显示合适的”。"),
 "No models downloaded yet.": ("아직 다운로드한 모델이 없습니다.", "まだダウンロードしたモデルはありません。", "尚未下载任何模型。"),
 "No open GGUF models match “%@”.": ("“%@”와 일치하는 공개 GGUF 모델이 없습니다.", "「%@」に一致する公開GGUFモデルはありません。", "没有与“%@”匹配的开放 GGUF 模型。"),
 "No ready-to-run GGUF files in this repo.": ("이 저장소에는 바로 실행 가능한 GGUF 파일이 없습니다.", "このリポジトリにはすぐ実行できるGGUFファイルがありません。", "此仓库中没有可直接运行的 GGUF 文件。"),
 "Not enough free space": ("여유 공간 부족", "空き容量が不足", "可用空间不足"),
 "Not enough memory": ("메모리 부족", "メモリ不足", "内存不足"),
 "OK": ("확인", "OK", "好"),
 "Off by default — models are multiple GB, so downloads wait for Wi-Fi. Turn this on to allow cellular data.":
   ("기본값은 꺼짐입니다 — 모델은 수 GB라 다운로드는 Wi-Fi를 기다립니다. 켜면 셀룰러 데이터를 허용합니다.",
    "既定ではオフ — モデルは数GBあるため、ダウンロードはWi-Fiを待ちます。オンにするとモバイル通信を許可します。",
    "默认关闭——模型有数 GB 大，下载会等待 Wi-Fi。开启后允许使用蜂窝数据。"),
 "Only this conversation. The defaults for every chat live in Settings.":
   ("이 대화에만 적용됩니다. 모든 채팅의 기본값은 설정에 있습니다.",
    "この会話のみに適用。全チャットの既定値は設定にあります。",
    "仅对本次对话生效。所有聊天的默认设置在“设置”中。"),
 "Open": ("열기", "開く", "打开"),
 "Open on Hugging Face": ("Hugging Face에서 열기", "Hugging Faceで開く", "在 Hugging Face 打开"),
 "Open source page": ("소스 페이지 열기", "ソースページを開く", "打开源代码页面"),
 "Open the model's page on huggingface.co": ("huggingface.co에서 모델 페이지 열기", "huggingface.coでモデルページを開く", "在 huggingface.co 打开模型页面"),
 "Or free up disk space and come back.": ("또는 디스크 공간을 확보한 뒤 다시 시도하세요.", "またはディスク容量を空けて、再度お試しください。", "或者清理磁盘空间后再试。"),
 "Plan novel goals (experimental)": ("새로운 목표 계획하기 (실험적)", "新規目標のプランニング（実験的）", "规划新目标（实验性）"),
 "Plan: ": ("계획: ", "計画: ", "计划："),
 "Preview": ("미리보기", "プレビュー", "预览"),
 "Preview of the chat appearance with the current settings":
   ("현재 설정 기준 채팅 모양 미리보기", "現在の設定でのチャット表示のプレビュー", "当前设置下的聊天外观预览"),
 "Privacy": ("개인정보 보호", "プライバシー", "隐私"),
 "Privacy Policy": ("개인정보 처리방침", "プライバシーポリシー", "隐私政策"),
 "Quality": ("품질", "品質", "质量"),
 "Quant & exact file size also refine files after you tap Show files.":
   ("양자화와 정확한 파일 크기는 파일 표시를 누른 뒤에도 목록을 좁혀 줍니다.",
    "量子化と正確なファイルサイズは、「ファイルを表示」後の絞り込みにも使えます。",
    "量化与精确文件大小也会在你点按“显示文件”后进一步筛选。"),
 "Quenderin": ("Quenderin", "Quenderin", "Quenderin"),
 "Quenderin agent run": ("Quenderin 에이전트 실행", "Quenderinエージェントの実行", "Quenderin 智能体运行"),
 "Quenderin conversation": ("Quenderin 대화", "Quenderinの会話", "Quenderin 对话"),
 "Quenderin is open source — view on GitHub": ("Quenderin은 오픈소스입니다 — GitHub에서 보기", "Quenderinはオープンソース — GitHubで見る", "Quenderin 是开源的——在 GitHub 上查看"),
 "READY TO USE": ("바로 사용 가능", "すぐ使える", "即可使用"),
 "RECENT GOALS": ("최근 목표", "最近の目標", "最近目标"),
 "RECOMMENDED FOR YOUR DEVICE": ("이 기기에 추천", "このデバイスへのおすすめ", "为你的设备推荐"),
 "RUN LOG": ("실행 로그", "実行ログ", "运行日志"),
 "Re-use goal: %@": ("목표 다시 사용: %@", "目標を再利用: %@", "重用目标：%@"),
 "Read the full terms": ("전체 약관 읽기", "利用規約の全文を読む", "阅读完整条款"),
 "Ready": ("준비됨", "準備完了", "已就绪"),
 "Reasoning": ("추론", "推論", "推理"),
 "Remove %@": ("%@ 제거", "%@を削除", "移除 %@"),
 "Remove from recents": ("최근 목록에서 제거", "最近の項目から削除", "从最近列表移除"),
 "Report answer": ("답변 신고", "回答を報告", "举报回答"),
 "Report response": ("응답 신고", "応答を報告", "举报回复"),
 "Retry": ("다시 시도", "再試行", "重试"),
 "Retry install": ("설치 다시 시도", "インストールを再試行", "重试安装"),
 "Retry install %@": ("%@ 설치 다시 시도", "%@のインストールを再試行", "重试安装 %@"),
 "Revoke workspace access": ("작업 폴더 접근 취소", "ワークスペースへのアクセスを取り消す", "撤销工作区访问权限"),
 "Routing": ("라우팅", "ルーティング", "路由"),
 "Runs entirely on your %@. Nothing you type leaves the device.":
   ("전부 당신의 %@에서 실행됩니다. 입력한 내용은 기기를 떠나지 않습니다.",
    "すべて%@上で動作します。入力内容がデバイスの外に出ることはありません。",
    "完全在你的%@上运行。你输入的内容不会离开设备。"),
 "Runs entirely on-device via llama.cpp — no cloud.":
   ("llama.cpp로 전부 기기에서 실행 — 클라우드 없음.", "llama.cppによりすべてオンデバイスで動作 — クラウドなし。", "通过 llama.cpp 完全在设备端运行——无云端。"),
 "Search": ("검색", "検索", "搜索"),
 "Search models — e.g. Qwen, Llama 8B, instruct…": ("모델 검색 — 예: Qwen, Llama 8B, instruct…", "モデルを検索 — 例: Qwen、Llama 8B、instruct…", "搜索模型——例如 Qwen、Llama 8B、instruct…"),
 "Search models — e.g. Qwen, Llama, Phi, Gemma…": ("모델 검색 — 예: Qwen, Llama, Phi, Gemma…", "モデルを検索 — 例: Qwen、Llama、Phi、Gemma…", "搜索模型——例如 Qwen、Llama、Phi、Gemma…"),
 "Search the open catalog": ("공개 카탈로그 검색", "公開カタログを検索", "搜索开放目录"),
 "Searching Hugging Face": ("Hugging Face 검색 중", "Hugging Faceを検索中", "正在搜索 Hugging Face"),
 "Searching Hugging Face…": ("Hugging Face 검색 중…", "Hugging Faceを検索中…", "正在搜索 Hugging Face…"),
 "Select a chat, or press ⌘N to start one.": ("채팅을 선택하거나 ⌘N을 눌러 시작하세요.", "チャットを選ぶか、⌘Nで新規作成。", "选择一个聊天，或按 ⌘N 开始。"),
 "Settings": ("설정", "設定", "设置"),
 "Share conversation": ("대화 공유", "会話を共有", "分享对话"),
 "Share walkthrough": ("과정 공유", "手順を共有", "分享过程"),
 "Show details…": ("세부 정보 표시…", "詳細を表示…", "显示详情…"),
 "Show in Finder": ("Finder에서 보기", "Finderで表示", "在访达中显示"),
 "Show the full ledger in Finder": ("전체 기록을 Finder에서 보기", "完全な記録をFinderで表示", "在访达中显示完整记录"),
 "Source": ("소스", "ソース", "源代码"),
 "Speed": ("속도", "速度", "速度"),
 "Start a chat with %@ — it runs entirely on your %@.":
   ("%1$@와 채팅을 시작하세요 — 전부 당신의 %2$@에서 실행됩니다.",
    "%1$@とチャットを始めましょう — すべて%2$@上で動作します。",
    "开始与 %1$@ 聊天——它完全在你的%2$@上运行。"),
 "Step %@": ("단계 %@", "ステップ %@", "步骤 %@"),
 "Stop": ("중지", "停止", "停止"),
 "Stop agent": ("에이전트 중지", "エージェントを停止", "停止智能体"),
 "Storage": ("저장 공간", "ストレージ", "存储"),
 "Suggest the best model for each task": ("작업마다 최적의 모델 제안", "タスクごとに最適なモデルを提案", "为每个任务推荐最佳模型"),
 "Support": ("지원", "サポート", "支持"),
 "Switch": ("전환", "切り替え", "切换"),
}

path = os.path.join(os.path.dirname(__file__), "translations.tsv")
lines = open(path, encoding="utf-8").read().split("\n")
out, hit = [], 0
for ln in lines:
    if ln.startswith("#") or not ln.strip():
        out.append(ln); continue
    cols = ln.split("\t")
    if len(cols) == 5 and cols[0] in T and (not cols[2] or not cols[3] or not cols[4]):
        cols[2], cols[3], cols[4] = T[cols[0]]
        hit += 1
    out.append("\t".join(cols))
open(path, "w", encoding="utf-8").write("\n".join(out))
keys_in_tsv = {l.split("\t")[0] for l in lines if l and not l.startswith("#")}
missed = [k for k in T if k not in keys_in_tsv]
print(f"chunk2: filled {hit} rows; {len(missed)} dict keys had no TSV row")
for k in missed: print("  MISS:", k[:90])
