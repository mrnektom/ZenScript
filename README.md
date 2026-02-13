# ZenScript language


## Basic syntax

### Constants and variables

1. Constant with initializer
    ```zs
    const name = value
    ```

2. Constant with explicit value type
    ```zs
    const name: number = 1 
    ```

### Branch conditions


1. Basic condition
    ```zs
   if (condition) {
        // do something   
   }
   
   // parens can be omitted 
   if condition {
       // do something
   }
   ```
2. Condition with else branch
    ```zs
   if (condition) {
       // do something
   } else {
       // do if condition falsy
   }
   
   if condition {
        // do something
   } else if condition {
        // do something if second condition truly
   }
    ```

### Loops

1. Basic loop
    ```zs
   loop {
        // do something
   }
    ```
2. Loop with condition
    ```zs
   while (condition) {
        // do while condition truly
   }
   
   // parens can be omitted
   while condition {
   }
    ```
   
### Functions

1. Basic function
    ```zs
   fn name(arg1: ArgType): RetType {
        // do something
        return value
   } 
    ```
   
