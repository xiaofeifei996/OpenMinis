from pathlib import Path
import subprocess, tempfile, argparse
r = Path(__file__).resolve().parents[1]
def read(p): return (r / 'src/ios' / p).read_text()
models = read('Agent/Chat/ChatModels.swift')
a = models.index('    @Published var isAwaitingModelResponse')
b = models.index('    /// True when this message is queued', a)
fields = models[a:b]
ui = read('Views/Chat/AssistantBlockView.swift')
indicator = 'struct TypingIndicator: View {' + ui.split('struct TypingIndicator: View {', 1)[1].split('// MARK: - Thinking Level Sheet', 1)[0]
for path in ['Views/Chat/ChatMessageViews.swift', 'Agent/MessageList/CollectionViewMessageListV3/Cells/BridgedAssistantFooterV3.swift']:
    text = read(path)
    assert 'TypingIndicator(startedAt: message.modelWaitStartedAt' in text
    assert 'phase: message.modelWaitPhase' in text
responses = read('Providers/OpenAI/OpenAIAgentProvider.swift').split('case "response.completed":', 1)[1].split('default:', 1)[0]
assert responses.index('continuation.yield(.usage(u))') < responses.index('continuation.finish()')
assert responses.index('functionCalls.flush(') < responses.index('continuation.finish()')
assert 'continuation.finish()\n                            return' in responses
anthropic = read('Providers/Anthropic/AnthropicAgentProvider.swift').split('case .messageStop:', 1)[1].split('catch', 1)[0]
assert 'continuation.finish()\n                            return' in anthropic
print('PASS: real footer wiring and final-protocol events finish after usage/tool flush')
p = argparse.ArgumentParser(); p.add_argument('--static-only', action='store_true')
if p.parse_args().static_only: raise SystemExit(0)
with tempfile.TemporaryDirectory() as d:
    src = Path(d) / 'main.swift'; exe = Path(d) / 'state'
    src.write_text('import Foundation\nimport Combine\nclass State: ObservableObject {\n' + fields + '''
}
let state = State()
precondition(state.modelWaitStartedAt == nil)
state.isAwaitingModelResponse = true
let first = state.modelWaitStartedAt
precondition(first != nil)
precondition(state.modelWaitPhase == "正在准备下一轮请求")
state.isAwaitingModelResponse = true
precondition(state.modelWaitStartedAt == first)
state.modelWaitPhase = "正在连接模型"
state.isAwaitingModelResponse = false
precondition(state.modelWaitStartedAt == nil && state.modelWaitPhase == nil)
state.isAwaitingModelResponse = true
precondition(state.modelWaitStartedAt != nil)
print("PASS: wait phase resets on real content/stop and restarts next round")
''')
    subprocess.run(['swiftc', str(src), '-o', str(exe)], check=True, timeout=60)
    subprocess.run([str(exe)], check=True, timeout=10)
    src.write_text('import SwiftUI\nenum ChatColors { static let tertiaryText = Color.gray }\n' + indicator)
    subprocess.run(['swiftc', '-typecheck', str(src)], check=True, timeout=60)
    print('PASS: production waiting indicator SwiftUI typecheck')
