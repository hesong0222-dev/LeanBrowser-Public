import SwiftUI

struct AgentPanel: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var agent: AgentController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    capabilityControls
                    proposalSection
                    jobSection
                    resultSection
                }
                .padding(.vertical, 2)
            }
        }
        .padding(24)
        .frame(width: 680, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("에이전트")
                    .font(.system(size: 22, weight: .semibold))
                Text("현재 탭의 구조화된 정보로 계획을 만들고 실행합니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("완료") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var capabilityControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("제어 범위")
                .font(.system(size: 13, weight: .semibold))

            Toggle("LeanBrowser 탭 제어", isOn: $agent.browserEnabled)
            Text("탭, 주소, 구조화된 페이지 요소를 현재 세션 안에서만 사용합니다.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider()

            Toggle("데스크톱 제어", isOn: $agent.desktopEnabled)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(agent.desktopPermissionText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("이 세션에 허용") {
                    agent.requestDesktopPermission()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 7) {
                Image(systemName: agent.socketStatus == "연결됨" ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(agent.socketStatus == "연결됨" ? Color.green : Color.secondary)
                Text("연결: \(agent.socketStatus)")
                    .font(.system(size: 12, weight: .medium))
            }

            Text("로그인은 LeanBrowser 전용 사이트 저장소에 유지됩니다. 쿠키와 비밀번호는 에이전트에 내보내지 않습니다.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(panelSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var proposalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("채팅 계획")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("채팅에서 명령 가져오기") {
                    Task { await agent.importChat() }
                }
                .disabled(agent.isImporting)
                Button("사용법 복사") { agent.copyInstructions() }
            }

            Text("사이트 내용은 제안일 뿐입니다. 가져온 계획을 확인한 뒤 ‘계획 실행’을 눌러야 명령이 시작됩니다.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $agent.proposalText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 92, maxHeight: 110)
                .padding(7)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.13), lineWidth: 1)
                }
                .accessibilityLabel("가져온 채팅 계획")

            HStack(spacing: 10) {
                Button("계획 실행") { agent.runProposal() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 47 / 255, green: 103 / 255, blue: 76 / 255))
                    .disabled(agent.proposalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("중단", role: .destructive) { agent.cancelAll() }
                    .buttonStyle(.bordered)
                if !agent.notice.isEmpty {
                    Text(agent.notice)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var jobSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("최근 작업")
                .font(.system(size: 13, weight: .semibold))
            if agent.jobs.isEmpty {
                Text("아직 실행한 계획이 없습니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(agent.jobs.prefix(5))) { job in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(statusLabel(job.status))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(statusColor(job.status))
                            .lineLimit(1)
                            .frame(width: 56, alignment: .leading)
                        Text(job.summary)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(job.created, style: .time)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("최근 결과")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("결과 복사") { agent.copyResult() }
                    .disabled(agent.latestResult.isEmpty)
            }
            Text(agent.latestResult.isEmpty ? "결과가 여기에 표시됩니다." : agent.latestResult)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(5)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var panelSurface: Color {
        Color(red: 197 / 255, green: 233 / 255, blue: 215 / 255).opacity(0.23)
    }

    private func statusLabel(_ status: String) -> String {
        ["queued": "대기", "running": "실행 중", "cancelling": "중단 중", "completed": "완료", "failed": "실패", "cancelled": "중단", "interrupted": "종료됨"][status] ?? status
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "completed": return .green
        case "failed", "cancelled", "interrupted": return .red
        default: return .secondary
        }
    }
}
