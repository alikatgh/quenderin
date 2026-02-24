# Contributing to Quenderin

Thank you for your interest in contributing to Quenderin! We welcome contributions from everyone.

## Code of Conduct

This project follows a simple code of conduct: be respectful, be constructive, and be collaborative.

## Getting Started

### Development Setup

1. Fork and clone the repository:
   ```bash
   git clone https://github.com/YOUR-USERNAME/quenderin.git
   cd quenderin
   ```

2. Install dependencies:
   ```bash
   npm install
   ```

3. Run the development build:
   ```bash
   npm run dev
   ```

4. Run tests:
   ```bash
   npm test
   ```

5. Run linter:
   ```bash
   npm run lint
   ```

## Development Workflow

### Before You Start

1. Check existing issues and PRs to avoid duplicates
2. For major changes, open an issue first to discuss the approach
3. Create a new branch for your work:
   ```bash
   git checkout -b feature/your-feature-name
   ```

### Making Changes

1. **Write tests** - All new features should include tests
2. **Follow code style** - Run `npm run lint` and `npm run format`
3. **Update docs** - Update README.md or other docs as needed
4. **Keep commits focused** - One logical change per commit

### Code Quality Standards

- **TypeScript**: Use strict typing, avoid `any` types
- **Tests**: Maintain or improve test coverage
- **Linting**: Code must pass ESLint checks
- **Formatting**: Use Prettier formatting (run `npm run format`)
- **No warnings**: Build must complete without TypeScript warnings

### Testing

```bash
# Run all tests
npm test

# Run tests in watch mode
npm run test:watch

# Run tests with coverage
npm run test:coverage
```

**Test Requirements:**
- All new features must have tests
- All bug fixes should include a test that catches the bug
- Aim for 70%+ code coverage

### Submitting Changes

1. **Ensure all tests pass**:
   ```bash
   npm run lint && npm test && npm run build
   ```

2. **Commit your changes**:
   ```bash
   git add .
   git commit -m "feat: add amazing feature"
   ```

   Use conventional commit messages:
   - `feat:` - New feature
   - `fix:` - Bug fix
   - `docs:` - Documentation changes
   - `test:` - Test updates
   - `refactor:` - Code refactoring
   - `chore:` - Maintenance tasks

3. **Push to your fork**:
   ```bash
   git push origin feature/your-feature-name
   ```

4. **Open a Pull Request**:
   - Use a clear, descriptive title
   - Describe what changed and why
   - Reference any related issues
   - Include screenshots for UI changes

## Project Structure

```
quenderin/
├── src/
│   ├── __tests__/       # Test files
│   ├── config.ts        # Configuration management
│   ├── providers.ts     # LLM provider abstraction
│   ├── unified-generator.ts  # Code generation logic
│   ├── ui-server.ts     # Web UI server
│   ├── index.ts         # CLI entry point
│   └── types.ts         # TypeScript types
├── ui/                  # Web UI assets
├── dist/                # Compiled output
└── docs/                # Documentation
```

## Areas for Contribution

### Good First Issues

Look for issues labeled `good first issue` - these are great for newcomers!

### High-Priority Areas

1. **Provider Support**: Add support for new LLM providers
2. **Testing**: Improve test coverage
3. **Documentation**: Improve guides and examples
4. **Error Handling**: Better error messages and recovery
5. **Performance**: Optimize code generation speed
6. **UI**: Enhance the web interface

### Feature Ideas

- Support for more LLM providers (Anthropic, Groq, etc.)
- Conversation history and context
- Code templates and snippets
- Project-aware code generation
- Integration with IDEs
- Batch code generation
- Custom system prompts

## Code Review Process

1. At least one maintainer will review your PR
2. We'll provide constructive feedback
3. Make requested changes by pushing to your branch
4. Once approved, a maintainer will merge your PR

**What we look for:**
- Functionality works as intended
- Tests pass and coverage is maintained
- Code follows project conventions
- Documentation is updated
- No breaking changes (unless discussed)

## Getting Help

- **Questions**: Open a GitHub Discussion
- **Bugs**: Open a GitHub Issue
- **Security**: See SECURITY.md

## License

By contributing to Quenderin, you agree that your contributions will be licensed under the MIT License.

---

Thank you for contributing to Quenderin! 🚀
