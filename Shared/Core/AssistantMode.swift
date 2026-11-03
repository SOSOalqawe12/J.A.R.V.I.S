import Foundation

/// Personalities / specialisations a conversation can start in.
enum AssistantMode: String, CaseIterable, Identifiable {
    case jarvis, tutor, translator, writer, coder, coach, brainstorm, chef

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jarvis: return "JARVIS"
        case .tutor: return "Tutor"
        case .translator: return "Interpreter"
        case .writer: return "Writer"
        case .coder: return "Coder"
        case .coach: return "Life coach"
        case .brainstorm: return "Brainstorm"
        case .chef: return "Chef"
        }
    }

    var icon: String {
        switch self {
        case .jarvis: return "circle.hexagongrid.circle"
        case .tutor: return "graduationcap"
        case .translator: return "character.bubble"
        case .writer: return "pencil.and.outline"
        case .coder: return "chevron.left.forwardslash.chevron.right"
        case .coach: return "figure.run"
        case .brainstorm: return "lightbulb"
        case .chef: return "fork.knife"
        }
    }

    var instructions: String? {
        switch self {
        case .jarvis:
            return nil
        case .tutor:
            return "Act as a patient tutor. Explain step by step, check understanding with a short question, and offer to make worksheets, flashcards (CSV) or summary PDFs."
        case .translator:
            return "Act as a live interpreter. Detect the language of each message and translate it into the other language of the conversation (default: English ⇄ Arabic). Reply with the translation only, natural and idiomatic, unless asked otherwise."
        case .writer:
            return "Act as a skilled writer and editor. Match the requested tone, keep a strong structure, and save longer pieces as documents (Markdown or PDF)."
        case .coder:
            return "Act as a senior software engineer. Write complete, runnable code, save it as files with the right extensions in Code/, and explain briefly how to run it."
        case .coach:
            return "Act as an encouraging life and fitness coach. Ask about goals, make realistic plans, and save plans as checklists or calendar events when useful."
        case .brainstorm:
            return "Act as a creative brainstorming partner. Generate many varied, surprising ideas, then help narrow down the best ones. Use images when visuals would help."
        case .chef:
            return "Act as a friendly chef. Suggest recipes for what the user has, scale portions, and save recipes and shopping lists as files."
        }
    }
}
