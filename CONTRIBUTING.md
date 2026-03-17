# Contributing to VoiceInput

Thank you for your interest in contributing to VoiceInput! This document provides guidelines and instructions for contributing.

## Development Setup

### Prerequisites

- macOS 13.0+
- Xcode Command Line Tools
- Swift 5.9+
- Volcano Engine speech recognition credentials (for testing)

### Getting Started

1. **Fork and clone the repository**

   ```bash
   git clone https://github.com/YOUR_USERNAME/VoiceInput.git
   cd VoiceInput
   ```

2. **Build and install locally**

   ```bash
   ./scripts/build-and-install.sh
   ```

   This will build the app and install it to `~/Applications/VoiceInput.app`.

3. **Run tests**

   ```bash
   # Quick CI test (build + protocol verification)
   ./scripts/ci-test.sh

   # E2E test with mock audio
   ./scripts/e2e-test-app.sh

   # E2E test with real microphone (5 seconds)
   ./scripts/e2e-test-mic.sh
   ```

## Development Workflow

### Making Changes

1. **Create a feature branch**

   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes**

   - Follow Swift naming conventions and style
   - Add tests for new functionality
   - Update documentation as needed

3. **Test your changes**

   ```bash
   # Run all tests
   ./scripts/comprehensive-test.sh

   # Or run specific test suites
   ./scripts/ci-test.sh
   ./scripts/e2e-test-app.sh
   ```

4. **Commit your changes**

   ```bash
   git add .
   git commit -m "feat: add your feature description"
   ```

   Follow [Conventional Commits](https://www.conventionalcommits.org/) format:
   - `feat:` — new feature
   - `fix:` — bug fix
   - `docs:` — documentation changes
   - `test:` — test changes
   - `refactor:` — code refactoring
   - `chore:` — maintenance tasks

5. **Push and create a pull request**

   ```bash
   git push origin feature/your-feature-name
   ```

   Then open a pull request on GitHub.

## Code Style

- Use Swift standard naming conventions
- Use 4 spaces for indentation (no tabs)
- Add comments for complex logic
- Keep functions focused and single-purpose
- Use meaningful variable and function names

## Testing

### Test Categories

1. **CI Tests** (`ci-test.sh`)
   - Build verification
   - Protocol encoding/decoding tests
   - Fast feedback (~10 seconds)

2. **E2E Tests** (`e2e-test-*.sh`)
   - Mock audio tests
   - Real microphone tests
   - Full integration tests

3. **Visual Tests** (`visual-test.py`)
   - UI component testing
   - Automated visual verification

### Writing Tests

- Add unit tests for new utility functions
- Add integration tests for new features
- Update E2E tests when changing core functionality
- Verify tests pass before submitting PR

## Project Architecture

Key files to understand:

- **VoiceInputApp.swift** — Entry point, AppDelegate, menu bar, hotkey handling
- **AudioCapture.swift** — Microphone audio capture and PCM conversion
- **VolcanoASR.swift** — WebSocket client for Volcano Engine ASR
- **VoiceInputPanel.swift** — Floating transcription panel UI
- **PasteboardPaste.swift** — Clipboard paste and restoration
- **Config.swift** — Configuration and credential management

## Common Tasks

### Adding a New Feature

1. Design the feature and consider edge cases
2. Add configuration options if needed (in `Config.swift`)
3. Implement core functionality
4. Add UI elements if needed
5. Write tests
6. Update documentation (README, inline comments)

### Fixing a Bug

1. Reproduce the bug
2. Write a failing test that demonstrates the bug
3. Fix the bug
4. Verify the test now passes
5. Check for similar issues elsewhere in the codebase

### Adding API Configuration

1. Add new key to `Config.swift`
2. Add UI field in `SettingsWindow.swift`
3. Update Keychain storage in `KeychainHelper.swift` if sensitive
4. Update documentation in README

## Pull Request Guidelines

### Before Submitting

- [ ] All tests pass
- [ ] New code has tests
- [ ] Documentation is updated
- [ ] Commit messages follow Conventional Commits
- [ ] Code follows project style

### PR Description

Include:
- What does this PR do?
- Why is this change needed?
- How was it tested?
- Are there any breaking changes?
- Screenshots/GIFs for UI changes

### Review Process

1. Automated tests will run on your PR
2. Maintainers will review your code
3. Address any feedback
4. Once approved, your PR will be merged

## Reporting Issues

### Bug Reports

Include:
- macOS version
- VoiceInput version (from menu bar > About)
- Steps to reproduce
- Expected vs actual behavior
- Relevant logs from `~/Library/Logs/VoiceInput.log`

### Feature Requests

Include:
- Clear description of the feature
- Use cases and benefits
- Potential implementation approach (optional)

## Questions?

- Open a [GitHub Discussion](https://github.com/liuhao04/VoiceInput/discussions) for questions
- Open a [GitHub Issue](https://github.com/liuhao04/VoiceInput/issues) for bugs/features
- Check existing issues and discussions first

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

Thank you for contributing! 🎉
