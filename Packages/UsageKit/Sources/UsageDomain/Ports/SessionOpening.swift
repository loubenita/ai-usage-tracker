/// Brings a session's terminal to the front, as `TerminalFocus` plans it. The app does this
/// only when the session panel's Open button is clicked.
public protocol SessionOpening: Sendable {
    func open(_ origin: SessionOrigin)
}
