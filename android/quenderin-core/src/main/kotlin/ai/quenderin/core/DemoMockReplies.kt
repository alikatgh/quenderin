package ai.quenderin.core

/**
 * Prompt-aware canned replies for [MockInferenceEngine] when no fixed canned string is injected.
 * Always honest about demo mode; answers a few offline-friendly patterns so day-one UI demos
 * don't look like a broken bot. Twin of iOS `DemoMockReplies`.
 */
object DemoMockReplies {
    const val DEMO_FOOTER_EN =
        "Demo mode: no native llama.cpp in this build — reply is canned. Link the engine for real on-device answers (android/INTEGRATION.md)."

    const val DEMO_FOOTER_RU =
        "Демо-режим: в этой сборке нет native llama.cpp — ответ заготовлен. Подключите движок для реальных ответов (android/INTEGRATION.md)."

    fun reply(prompt: String): String {
        // Match on the LAST user turn only: the mock engine receives the whole flat transcript, and
        // the system prompt's "…send email…" used to route every unmatched message ("Hello") into the
        // canned email draft. Twin of Swift `DemoMockReplies.lastUserTurn` (2026-09-05).
        val trimmed = lastUserTurn(prompt).trim()
        val lower = trimmed.lowercase()
        val ru = looksRussian(trimmed)

        if (matchesMath17of240(lower) || lower.contains("17% от 240") || lower.contains("17 % от 240")) {
            val body = if (ru) {
                "17% от 240 = 0,17 × 240 = **40,8**."
            } else {
                "17% of 240 = 0.17 × 240 = **40.8**."
            }
            return body + "\n\n" + if (ru) DEMO_FOOTER_RU else DEMO_FOOTER_EN
        }

        if (lower.contains("jet lag") || lower.contains("джетлаг") || lower.contains("時差") || lower.contains("시차")) {
            val body = if (ru) {
                "Джетлаг — это когда внутренние часы ещё «дома», а вы уже в другом часовом поясе. Сон и бодрость сбиваются; обычно выравнивается за несколько дней (свет, режим, терпение)."
            } else {
                "Jet lag is when your body clock is still on home time but you are in another zone. Sleep and energy feel off; light, routine, and a few days usually re-sync you."
            }
            return body + "\n\n" + if (ru) DEMO_FOOTER_RU else DEMO_FOOTER_EN
        }

        if (lower.contains("packing") || lower.contains("checklist") || lower.contains("чек") || lower.contains("сборов")) {
            val body = if (ru) {
                "**Сумка:** паспорт, кошелёк, ключи, зарядка.\n**Одежда:** 2–3 комплекта, удобная обувь, слой от дождя.\n**Техника:** телефон, кабель, power bank.\n**Документы:** билеты/бронь, страховка."
            } else {
                "**Bag:** ID, wallet, keys, charger.\n**Clothes:** 2–3 outfits, comfy shoes, light rain layer.\n**Tech:** phone, cable, power bank.\n**Documents:** tickets/bookings, insurance card."
            }
            return body + "\n\n" + if (ru) DEMO_FOOTER_RU else DEMO_FOOTER_EN
        }

        if (lower.contains("eggs and rice") || lower.contains("яиц и риса") || lower.contains("dinner ideas")) {
            val body = if (ru) {
                "1) Яичница с рисом и зелёным луком\n2) Жареный рис с яйцом\n3) Омлет + рис с соевым соусом\n4) Рисовая каша с варёным яйцом\n5) Яйцо пашот на рисе с кунжутом"
            } else {
                "1) Fried eggs over rice with scallions\n2) Egg fried rice\n3) Omelette + soy rice\n4) Soft rice porridge with a boiled egg\n5) Poached egg on rice with sesame"
            }
            return body + "\n\n" + if (ru) DEMO_FOOTER_RU else DEMO_FOOTER_EN
        }

        if (lower.contains("email") || lower.contains("meeting") || lower.contains("письм") || lower.contains("встреч")) {
            val body = if (ru) {
                "Тема: Не смогу на встрече\n\nЗдравствуйте,\n\nк сожалению, в это время у меня конфликт в расписании и я не смогу присоединиться. Можем перенести на другой слот на этой неделе?\n\nСпасибо за понимание."
            } else {
                "Subject: Need to reschedule\n\nHi,\n\nI have a schedule conflict and can't make the meeting. Could we pick another slot this week?\n\nThanks for understanding."
            }
            return body + "\n\n" + if (ru) DEMO_FOOTER_RU else DEMO_FOOTER_EN
        }

        return if (ru) {
            "Демо-режим: это сборка без native llama.cpp, ответы заготовлены, пока движок не подключён (см. android/INTEGRATION.md). UI, загрузка моделей и история чата уже работают — для настоящих ответов свяжите llama.cpp."
        } else {
            "Demo mode: this build has no native llama.cpp. Replies are canned until you link " +
                "libquenderin_llama.so (see android/INTEGRATION.md). Your UI and download flow still work."
        }
    }

    /** The final "User: …" turn of a flat transcript (up to the next "Assistant:" line), or the prompt itself. */
    fun lastUserTurn(prompt: String): String {
        val start = prompt.lastIndexOf("User: ")
        if (start < 0) return prompt
        val tail = prompt.substring(start + "User: ".length)
        val end = tail.indexOf("\nAssistant:")
        return if (end >= 0) tail.substring(0, end) else tail
    }

    private fun matchesMath17of240(lower: String): Boolean {
        val pct = lower.contains("17%") || lower.contains("17 %") || lower.contains("17 percent")
        return pct && lower.contains("240")
    }

    private fun looksRussian(s: String): Boolean =
        s.any { it.code in 0x0400..0x04FF }
}
