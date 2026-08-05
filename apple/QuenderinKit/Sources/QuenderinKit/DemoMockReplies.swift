import Foundation

/// Prompt-aware canned replies for `MockInferenceEngine` when no fixed `cannedReply` is injected.
/// Always honest about demo mode; answers a few offline-friendly patterns so day-one UI demos
/// don't look like a broken bot. Twin of Android `DemoMockReplies`.
public enum DemoMockReplies: Sendable {
    public static let demoFooterEN =
        "Demo mode: no native llama.cpp in this build — reply is canned. Link the engine for real on-device answers (QuenderinKit INTEGRATION.md)."

    public static let demoFooterRU =
        "Демо-режим: в этой сборке нет native llama.cpp — ответ заготовлен. Подключите движок для реальных ответов (QuenderinKit INTEGRATION.md)."

    /// Pick a short demo reply for `prompt`. Prefer useful preview for starter-like asks; otherwise honesty.
    public static func reply(for prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let ru = looksRussian(trimmed)

        if matchesMath17of240(lower) || lower.contains("17% от 240") || lower.contains("17% от 240") {
            let body = ru
                ? "17% от 240 = 0,17 × 240 = **40,8**."
                : "17% of 240 = 0.17 × 240 = **40.8**."
            return body + "\n\n" + (ru ? demoFooterRU : demoFooterEN)
        }

        if lower.contains("jet lag") || lower.contains("джетлаг") || lower.contains("時差") || lower.contains("시차") {
            let body = ru
                ? "Джетлаг — это когда внутренние часы ещё «дома», а вы уже в другом часовом поясе. Сон и бодрость сбиваются; обычно выравнивается за несколько дней (свет, режим, терпение)."
                : "Jet lag is when your body clock is still on home time but you are in another zone. Sleep and energy feel off; light, routine, and a few days usually re-sync you."
            return body + "\n\n" + (ru ? demoFooterRU : demoFooterEN)
        }

        if lower.contains("packing") || lower.contains("checklist") || lower.contains("чек") || lower.contains("сборов") {
            let body = ru
                ? "**Сумка:** паспорт, кошелёк, ключи, зарядка.\n**Одежда:** 2–3 комплекта, удобная обувь, слой от дождя.\n**Техника:** телефон, кабель, power bank.\n**Документы:** билеты/бронь, страховка."
                : "**Bag:** ID, wallet, keys, charger.\n**Clothes:** 2–3 outfits, comfy shoes, light rain layer.\n**Tech:** phone, cable, power bank.\n**Documents:** tickets/bookings, insurance card."
            return body + "\n\n" + (ru ? demoFooterRU : demoFooterEN)
        }

        if lower.contains("eggs and rice") || lower.contains("яиц и риса") || lower.contains("dinner ideas") {
            let body = ru
                ? "1) Яичница с рисом и зелёным луком\n2) Жареный рис с яйцом\n3) Омлет + рис с соевым соусом\n4) Рисовая каша с варёным яйцом\n5) Яйцо пашот на рисе с кунжутом"
                : "1) Fried eggs over rice with scallions\n2) Egg fried rice\n3) Omelette + soy rice\n4) Soft rice porridge with a boiled egg\n5) Poached egg on rice with sesame"
            return body + "\n\n" + (ru ? demoFooterRU : demoFooterEN)
        }

        if lower.contains("email") || lower.contains("meeting") || lower.contains("письм") || lower.contains("встреч") {
            let body = ru
                ? "Тема: Не смогу на встрече\n\nЗдравствуйте,\n\nк сожалению, в это время у меня конфликт в расписании и я не смогу присоединиться. Можем перенести на другой слот на этой неделе?\n\nСпасибо за понимание."
                : "Subject: Need to reschedule\n\nHi,\n\nI have a schedule conflict and can't make the meeting. Could we pick another slot this week?\n\nThanks for understanding."
            return body + "\n\n" + (ru ? demoFooterRU : demoFooterEN)
        }

        // Generic honest reply (locale-aware).
        if ru {
            return "Демо-режим: это сборка без native llama.cpp, ответы заготовлены, пока движок не подключён (см. QuenderinKit INTEGRATION.md). UI, загрузка моделей и история чата уже работают — для настоящих ответов свяжите llama.cpp."
        }
        return "Demo mode: this build has no native llama.cpp. Replies are canned until llama is linked (see QuenderinKit INTEGRATION.md). Your UI and download flow still work."
    }

    private static func matchesMath17of240(_ lower: String) -> Bool {
        (lower.contains("17%") || lower.contains("17 %") || lower.contains("17 percent"))
            && lower.contains("240")
    }

    private static func looksRussian(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
    }
}
