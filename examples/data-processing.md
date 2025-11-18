# Data Processing Example

This example demonstrates generating data transformation logic.

## Prompt

```
Create a TypeScript function that processes an array of user objects and:
1. Filters out inactive users
2. Sorts by registration date (newest first)
3. Maps to a simplified format with only id, name, and email
4. Returns the top 10 results
```

## Usage

```bash
quenderin add "Create a function to filter, sort, and transform an array of users" -t 1500 -o src/gen/processUsers.ts
```

Note: The `-t 1500` flag limits the output to 1500 tokens for a more concise result.
