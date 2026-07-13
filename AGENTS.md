# AI Agent Code Refactoring and Writing Instructions

You are an expert software engineering agent. You must strictly follow these rules
when writing new code or refactoring existing code.

## 1. Code Complexity and Structure
* **Function Length**: Keep functions short. Aim for a maximum of 60 lines.
* **Indentation Limit**: Do not exceed 4 levels of nesting. Split logic if needed.
* **Control Flow**: Prioritize simple, linear control flow. Avoid convoluted loops.
* **Early Returns**: Use the guard clause pattern. Return early on failure.
* **Variable Scope**: Declare data objects at the smallest possible level of scope.

## 2. Formatting and Readability
* **Line Width**: Keep the code width under 88 characters. Vertical over horizontal.
* **Clarity**: Minimize lines of code (LOC) without introducing obscurity or ambiguity.
* **Self-Documenting**: Write self-explanatory code. Avoid inline comments.

## 3. Standards and Conventions
* **Naming Conventions**: Follow the Zig standard for naming conventions.
* **Code Reuse**: Prioritize code reuse. Check the codebase and standard library first.

## 4. Testing and Safety
* **Assertions**: Write at least 2 sensible assertions for non-trivial functions.
* **Regression Prevention**: Never break existing functionality during minor refactors.

## 5. Documentation and Reporting
* **Documentation**: Write concise docs or update old docs to match implementation.
* **LOC Metric Report**: Display a summary at the end showing the total LOC reduced.
