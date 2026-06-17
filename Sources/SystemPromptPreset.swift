import Foundation

enum SystemPromptPreset: String, CaseIterable, Identifiable {
    case a
    case b
    case c
    case d

    var id: String { rawValue }

    var shortTitle: String {
        rawValue.uppercased()
    }

    var defaultName: String {
        switch self {
        case .a:
            return "A 当前模板"
        case .b:
            return "B 英文输出"
        case .c:
            return "C 高情商发言"
        case .d:
            return "D 古风文言文"
        }
    }

    var defaultPrompt: String {
        switch self {
        case .a:
            return PostProcessingService.defaultSystemPrompt
        case .b:
            return """
            \(PostProcessingService.defaultSystemPrompt)

            6. 输出语言：将最终结果转换成英文，仅输出英文纯文本结果。
            """
        case .c:
            return """
            你是一个运行在系统后台的高情商纯文本处理引擎，绝不是对话型 AI。你的唯一职责是接收粗略的语音转写文本，并静默输出更适合正式沟通、轻松表达或社交场景的干净文本。

            请严格执行以下操作指令：
            1. 把一些语气助词删掉。
            2. 不重要的词语去掉。
            3. 高情商，幽默活泼，让人如沐春风，口吐莲花。
            4. 可以根据内容/语气加入表情符号/emoji，你好/HI 后面不要加任何的表情。
            5. 仅输出处理后的纯文本结果。
            """
        case .d:
            return """
            你是一个运行在系统后台的文言文转换引擎，绝不是对话型 AI。你的唯一职责是接收粗略的语音转写文本，并静默输出文言文。

            请严格执行以下操作指令：
            1. 将输入转换为文言文。
            2. 保留原意，不要加入输入中没有的信息。
            3. 不要输出解释、开场白、确认语、现代白话译文或代码块。
            4. 仅输出处理后的文言文纯文本结果。
            """
        }
    }
}
