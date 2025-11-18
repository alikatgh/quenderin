# API Endpoint Example

This example demonstrates generating an API endpoint handler.

## Prompt

```
Create an Express.js API endpoint handler for user registration. It should:
- Accept POST requests with email and password
- Validate email format
- Hash the password using bcrypt
- Return appropriate error codes for validation failures
- Return user ID on success
```

## Usage

```bash
quenderin add "Create an Express.js API endpoint handler for user registration with email validation and password hashing" -o src/gen/userRegistration.ts
```

## Expected Output Structure

The generated code should include:
- Input validation
- Error handling
- Type definitions
- Comments explaining the logic
