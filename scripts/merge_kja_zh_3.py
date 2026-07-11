#!/usr/bin/env python3
"""Chunk 3/3: fill ko/ja/zh-Hans columns (keys T–Z + symbols + language labels)."""
import os

T = {
 "Tap to expand → pick a file → Get": ("탭하여 펼치기 → 파일 선택 → 받기", "タップして展開 → ファイルを選択 → 入手", "点按展开 → 选择文件 → 获取"),
 "Tap “All results”, turn off “fits RAM”, or raise max size / download.":
   ("“모든 결과”를 탭하거나 “RAM에 맞는 것만”을 끄거나 최대 크기/다운로드를 올리세요.",
    "「すべての結果」をタップ、「RAMに収まるもののみ」をオフ、または最大サイズ/ダウンロードを引き上げてください。",
    "点按“全部结果”，关闭“适合内存”，或调高最大大小/下载限制。"),
 "Tell the agent what to do on your Mac": ("에이전트에게 Mac에서 할 일을 알려주세요", "エージェントにMacでやることを伝えてください", "告诉智能体要在你的 Mac 上做什么"),
 "Text size": ("텍스트 크기", "文字サイズ", "文字大小"),
 "The agent needs a loaded model.": ("에이전트에는 로드된 모델이 필요합니다.", "エージェントには読み込み済みモデルが必要です。", "智能体需要已加载的模型。"),
 "The ⋯ menu on each model can delete it and free space — the active model is protected.":
   ("각 모델의 ⋯ 메뉴에서 삭제해 공간을 확보할 수 있습니다 — 활성 모델은 보호됩니다.",
    "各モデルの⋯メニューから削除して容量を空けられます — 使用中のモデルは保護されます。",
    "每个模型的 ⋯ 菜单可删除它以释放空间——当前使用的模型受保护。"),
 "Their transcripts and per-chat settings are removed from this Mac. This can't be undone.":
   ("대화 내용과 채팅별 설정이 이 Mac에서 삭제됩니다. 되돌릴 수 없습니다.",
    "トランスクリプトとチャットごとの設定がこのMacから削除されます。元に戻せません。",
    "它们的记录和各自设置将从这台 Mac 上删除。此操作无法撤销。"),
 "Theme": ("테마", "テーマ", "主题"),
 "They download one after another and can be deleted any time in Settings → Storage.":
   ("모델은 차례로 다운로드되며 설정 → 저장 공간에서 언제든 삭제할 수 있습니다.",
    "モデルは順番にダウンロードされ、設定 → ストレージからいつでも削除できます。",
    "它们会依次下载，并可随时在设置 → 存储中删除。"),
 "This is the model you’re using now.": ("지금 사용 중인 모델입니다.", "現在使用中のモデルです。", "这是你当前使用的模型。"),
 "This model needs ~%@ GB — your %@ has %@ GB free.":
   ("이 모델에는 약 %1$@ GB가 필요합니다 — 당신의 %2$@에는 %3$@ GB의 여유가 있습니다.",
    "このモデルには約%1$@ GBが必要です — あなたの%2$@の空きは%3$@ GBです。",
    "此模型需要约 %1$@ GB——你的%2$@有 %3$@ GB 可用。"),
 "This removes every saved conversation from this %@. It can't be undone.":
   ("저장된 모든 대화가 이 %@에서 삭제됩니다. 되돌릴 수 없습니다.",
    "保存されたすべての会話がこの%@から削除されます。元に戻せません。",
    "这将从这台%@上删除所有已保存的对话。无法撤销。"),
 "To get ready, resolve: ": ("준비를 위해 해결하세요: ", "準備のために解決してください: ", "要就绪，请先解决："),
 "Try a family name like Qwen, Llama, Phi, or Mistral — or clear filters above.":
   ("Qwen, Llama, Phi, Mistral 같은 계열 이름을 검색하거나 위 필터를 지워 보세요.",
    "Qwen・Llama・Phi・Mistralなどのファミリー名で試すか、上のフィルタを解除してください。",
    "试试 Qwen、Llama、Phi 或 Mistral 这类系列名——或清除上面的筛选。"),
 "Try searching for": ("이런 검색어를 시도해 보세요", "こんな検索を試す", "试试搜索"),
 "Type at least 2 characters. Tip: look for a GGUF re-upload (e.g. TheBloke or bartowski) — those are ready-to-run files; smaller quants (Q4) fit more hardware.":
   ("2자 이상 입력하세요. 팁: GGUF 재업로드(예: TheBloke, bartowski)를 찾으세요 — 바로 실행 가능한 파일이며, 작은 양자화(Q4)일수록 더 많은 기기에 맞습니다.",
    "2文字以上入力してください。ヒント: GGUFの再アップロード（例: TheBloke、bartowski）を探しましょう — すぐ実行できるファイルで、小さい量子化（Q4）ほど多くのハードウェアに収まります。",
    "请至少输入 2 个字符。提示：找 GGUF 转载版（如 TheBloke 或 bartowski）——那些是即开即用的文件；更小的量化（Q4）适配更多硬件。"),
 "Undo last move": ("마지막 이동 취소", "直前の移動を取り消す", "撤销上一次移动"),
 "Undo task changes (%lld)": ("작업 변경 사항 취소 (%lld)", "タスクの変更を取り消す（%lld）", "撤销任务更改（%lld）"),
 "Use": ("사용", "使う", "使用"),
 "Use %@": ("%@ 사용", "%@を使う", "使用 %@"),
 "Use example: %@": ("예시 사용: %@", "例を使う: %@", "使用示例：%@"),
 "Use this model": ("이 모델 사용", "このモデルを使う", "使用此模型"),
 "Use with judgement": ("신중하게 사용하세요", "判断力を持って使う", "理性使用"),
 "Version %@": ("버전 %@", "バージョン %@", "版本 %@"),
 "Version %@ — on-device · private · open source":
   ("버전 %@ — 온디바이스 · 프라이빗 · 오픈소스", "バージョン %@ — オンデバイス · プライベート · オープンソース", "版本 %@——设备端 · 私密 · 开源"),
 "View the source on GitHub": ("GitHub에서 소스 보기", "GitHubでソースを見る", "在 GitHub 上查看源代码"),
 "Warming up %@…": ("%@ 준비 중…", "%@をウォームアップ中…", "正在预热 %@…"),
 "What do these mean?": ("이것들은 무슨 뜻인가요?", "これらの意味は？", "这些是什么意思？"),
 "What these mean": ("의미 설명", "これらの意味", "含义说明"),
 "Why is this recommended?": ("왜 이것을 추천하나요?", "なぜこれがおすすめ？", "为什么推荐这个？"),
 "Why this one?": ("왜 이 모델인가요?", "なぜこれ？", "为什么是这个？"),
 "You can download %@ again any time — it just won't be on this %@.":
   ("%1$@는 언제든 다시 다운로드할 수 있습니다 — 이 %2$@에 남아 있지 않을 뿐입니다.",
    "%1$@はいつでも再ダウンロードできます — この%2$@に残らないだけです。",
    "你可以随时重新下载 %1$@——只是它不再占用这台%2$@的空间。"),
 "You give a goal. The agent plans steps, uses tools on this device, and shows each step in the run log. Mutating actions always ask you first.":
   ("당신이 목표를 주면, 에이전트가 단계를 계획하고 이 기기의 도구를 사용하며 각 단계를 실행 로그에 보여줍니다. 무언가를 바꾸는 동작은 항상 먼저 물어봅니다.",
    "あなたが目標を与えると、エージェントはステップを計画し、このデバイスのツールを使い、各ステップを実行ログに表示します。変更を伴う操作は必ず先に確認します。",
    "你给出目标。智能体规划步骤、使用本机工具，并在运行日志中展示每一步。会产生更改的操作总是先征求你的同意。"),
 "You’ll still confirm before it changes anything — this only turns the capability on.":
   ("무언가를 바꾸기 전에는 여전히 확인을 거칩니다 — 이 스위치는 기능을 켤 뿐입니다.",
    "何かを変更する前には必ず確認があります — これは機能をオンにするだけです。",
    "在它做出任何更改前你仍需确认——这只是开启该能力。"),
 "Your device can run %@ (%@)": ("이 기기는 %1$@ 실행 가능 (%2$@)", "このデバイスは%1$@を実行可能（%2$@）", "你的设备可运行 %1$@（%2$@）"),
 "%@ is running fully on-device.": ("%@가 완전히 기기에서 실행 중입니다.", "%@は完全にオンデバイスで動作中です。", "%@ 正完全在设备端运行。"),
 "%@ · one time, then it's yours offline": ("%@ · 한 번만 받으면 오프라인에서 계속 사용", "%@ · 一度きり、その後はオフラインで利用可能", "%@ · 一次下载，永久离线可用"),
 "%@ · %@ downloads": ("%1$@ · 다운로드 %2$@회", "%1$@ · ダウンロード %2$@件", "%1$@ · %2$@ 次下载"),
 "%lld": ("%lld", "%lld", "%lld"),
 "%lld chats selected": ("채팅 %lld개 선택됨", "%lld件のチャットを選択中", "已选择 %lld 个聊天"),
 "%lld models downloading": ("모델 %lld개 다운로드 중", "%lld個のモデルをダウンロード中", "%lld 个模型下载中"),
 "%lld of %lld installed · %@ on disk · %@ free":
   ("%1$lld/%2$lld 설치됨 · 디스크 %3$@ · 여유 %4$@",
    "%1$lld/%2$lld個をインストール済み · ディスク%3$@ · 空き%4$@",
    "已安装 %1$lld/%2$lld · 占用 %3$@ · 可用 %4$@"),
 "%@ — workspace": ("%@ — 작업 폴더", "%@ — ワークスペース", "%@——工作区"),
 "on-device · private": ("온디바이스 · 프라이빗", "オンデバイス · プライベート", "设备端 · 私密"),
 "· the agent's plan": ("· 에이전트의 계획", "· エージェントの計画", "· 智能体的计划"),
 "Goal: %@": ("목표: %@", "目標: %@", "目标：%@"),
 "⌘-click rows to change the selection; ⇧-click selects a range.":
   ("⌘-클릭으로 선택을 바꾸고, ⇧-클릭으로 범위를 선택합니다.",
    "⌘クリックで選択を変更、⇧クリックで範囲を選択。",
    "⌘-点按更改所选行；⇧-点按选择范围。"),
 "Last active ": ("마지막 활동: ", "最終アクティブ: ", "最近使用："),
 "Languages": ("언어", "言語", "语言"),
 "Russian, English, Chinese + 100 more": ("러시아어·영어·중국어 외 100개 이상", "ロシア語・英語・中国語 + 100以上", "俄语、英语、中文 + 100 多种"),
 "Russian, English, Chinese + 25 more": ("러시아어·영어·중국어 외 25개", "ロシア語・英語・中国語 + 25", "俄语、英语、中文 + 25 种"),
 "Russian, English + 140 more": ("러시아어·영어 외 140개", "ロシア語・英語 + 140", "俄语、英语 + 140 种"),
 "English & Chinese — weak Russian": ("영어·중국어 — 러시아어 약함", "英語・中国語 — ロシア語は苦手", "英语和中文——俄语较弱"),
 "English-focused — weak Russian": ("영어 중심 — 러시아어 약함", "英語中心 — ロシア語は苦手", "以英语为主——俄语较弱"),
 "English + European — weak Russian": ("영어·유럽 언어 — 러시아어 약함", "英語＋欧州言語 — ロシア語は苦手", "英语+欧洲语言——俄语较弱"),
 "English + 7 more — no Russian": ("영어 외 7개 — 러시아어 없음", "英語 + 7言語 — ロシア語なし", "英语 + 7 种——不支持俄语"),
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
print(f"chunk3: filled {hit} rows; {len(missed)} dict keys had no TSV row")
for k in missed: print("  MISS:", k[:90])
