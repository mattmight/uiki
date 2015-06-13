# Main page #

Welcome to the main page.

To configure this wiki, edit `config.rkt` in the root directory.


## Wiki syntax

You can link to new pages by enclosing their name in <code>&#91;&#91;</code> and `]]`, as in [[The Sandbox]].

You can use the pipe <code>&#91;&#91;</code>`target|text]]` notation to [[The Sandbox|redirect]] a within-wiki link.


## Markdown syntax

Markdown syntax is supported by [multimarkdown].


## LaTeX syntax

Inline LaTeX syntax is supported with `$`-notation, so that `$f(x)$` produces $f(x)$.

Equation blocks are supported by surrounding LaTeX with `\\[` and `\\]`, so that

```
\\[
 Z = \int_0^\infty g(x)d(x)
\\]
```

produces:

\\[
 Z = \int_0^\infty g(x)d(x)
\\]


## Syntax highlighting

You can render code with syntax highlighting in 
a fenced block by specifying the language, so that:

`````
````javascript
function main () {
   printf("Running some code.")
}
````
`````

produces:

```javascript
function main () {
   printf("Running some code.")
}
```



[multimarkdown]:  http://fletcherpenney.net/multimarkdown/


