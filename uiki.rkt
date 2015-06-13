#lang racket


; DEPENDENCIES:

; + racket 6.1.1+ (earlier versions might work)
; + git
; + multimarkdown
; + sed

; FEATURES:

; + Markdown support via multimarkdown
; + LaTeX support via MathJax
; + Syntax highlighting support via code-prettify
; + Backup/versioning support via git

; KNOWN BUGS:

; + No warning on racing edits.

; TODO:

; + Include suffices in links, e.g., [[cat]]s renders as `cats`
; + Add web interface for version control
; + Add support for local install of MathJax
; + Add support for local install of code-prettify
; + Add support for git over ssh access to page repos
; + Add support for git over http access to page repos (git-http-backend)
; + Add support for site-wide LaTeX macro files inclusion
; + Add support for HTTP authentication
; + Allow uplodaing images
; + Allow uploading other file types (pdf)
; + Add support for citation management with .bib files

; SECURITY ISSUES:

; + Strip out problematic (all?) HTML tags: script, style, etc.
; + Verify absence of injection for shell/system/process uses.

; CONSIDER:

; + Could git submodules allow database to be giant module?
;   Would this allow checking out entire wiki db locally?


(require web-server/servlet
         web-server/servlet-env)

(require web-server/private/mime-types)

(require xml)

(require parser-tools/lex)
(require (prefix-in : parser-tools/lex-sre))

(require net/uri-codec)

(require file/sha1)
(require net/base64)


; Import configuration variables:
(include "config.rkt")


; Functional programming helpers:
(define (any? pred list)
  ; returns true iff any element matches pred:
  (match list
    ['()  #f]
    [(cons hd tl)
     (or (pred hd) (any? pred (cdr list)))]))


; I/O and filesystem helpers:
(define (file->bytes filename)
  ; read a file into bytes;
  (call-with-input-file filename port->bytes))

(define (file->string filename)
  ; read a file into a string:
  (call-with-input-file filename port->string))

(define (file-extension path)
  ; extract the extension from the file at the end of the path:
  (define path-parts (string-split path "/"))
  (define name-parts (string-split (last path-parts) "."))
  (if (= (length name-parts) 1)
      ""
      (last name-parts)))


; Shell interaction:
(define ($ command)
  ; run a shell command, then
  ; print out stdout, stderr as needed:
  (match (process command)
    [`(,stdout ,stdin ,exit ,stderr ,proc)
     (define cmd-out (port->string stdout))
     (define cmd-err (port->string stderr))
     
     (printf "$ command~n~a~n" cmd-out)
     
     (when (not (equal? cmd-err ""))
       (printf "~nerror:~n~a~n" cmd-err))]))


; Wiki text mark-up routines:
(define wikify-text
  ; convert a port into a list of strings,
  ; converting wiki mark-ups in the process:
  (lexer
   [(:: "[[" (complement (:: any-string "]]" any-string)) "]]")
    (begin
      (define text (substring lexeme 2 (- (string-length lexeme) 2)))
      (define target:text (string-split text "|"))
      (define link 
        (match target:text
          [`(,target)         (wikify-link target)]
          [`(,target ,text)   (wikify-link target text)]))
      (cons link (wikify-text input-port)))]
      
   [any-char
    (cons lexeme (wikify-text input-port))]
   
   [(eof)
    '()]))

(define (wikify-target target)
  ; sanitize a link target:
  (string-replace (string-downcase target) #px"[\\W]" "-"))

(define (wikify-link target [text #f])
  ; create an anchor tag:
  (define safe-target (wikify-target target))
  (string-append 
   "<a href=\"/wiki/" safe-target "\">" 
   (if text text target)
   "</a>"))


; Page-generation helpers:
(define (generate-head-xexpr
         #:title [title "no title"]
         #:style [style ""])
  ; generate a page header:
  `(head 
    (title ,title)
    (style 
     ,(string-append default-style "\n" style))))


; Basic HTTP request processing helpers:
(define ext=>mime-type (read-mime-types mime-types-file))


; HTTP Basic Authentication:
(define (htpasswd-credentials-valid?
         passwd-file
         username
         password)
  ; checks if the given credentials match those in the database
  ; it assumes all entries as SHA1-encoded as in `htpasswd -s`.

  ; read in the lines from the password file:
  (define lines (call-with-input-file passwd-file 
                  (λ (port) (port->lines port))))
  
  ; convert the password to sha1:
  (define sha1-pass (sha1-bytes (open-input-bytes password)))
  
  ; then to base64 encoding:
  (define sha1-pass-b64 
    (bytes->string/utf-8 (base64-encode sha1-pass #"")))
  
  ; check if both the username and the password match:
  (define (password-matches? line)

      (define user:hash (string-split line ":"))
      
      (define user (car user:hash))
      (define hash (cadr user:hash))
      
      (match (string->list hash)
        ; check for SHA1 prefix
        [`(#\{ #\S #\H #\A #\} . ,hashpass-chars)
         (define hashpass (list->string hashpass-chars))
         (and (equal? username (string->bytes/utf-8 user)) 
              (equal? hashpass sha1-pass-b64))]))
  
  ; check to see if any line validates:
  (any? password-matches? lines))

(define (authenticated? passwd-file req)
  ; checks if a request has valid credentials:
  (match (request->basic-credentials req)
    [(cons user pass)
     (htpasswd-credentials-valid? passwd-file user pass)]
    
    [else     #f]))


; A handler for static files:
(define (handle-file-request req docroot path)
  
  ; identify the requested file:
  (define file (string-append docroot "/" (string-join path "/")))
  
  (cond
    [(file-exists? file)
     ; =>
     (define extension (string->symbol (file-extension file)))
     (define content-type 
       (hash-ref ext=>mime-type extension 
                 (λ () TEXT/HTML-MIME-TYPE)))
     
     ; send the requested file back:
     (response
      200 #"OK"            ; code & message
      (current-seconds)    ; timestamp
      content-type         ; content-type
      '()                  ; additional headers
      (λ (client-out)
        (write-bytes (file->bytes file) client-out)))]
    
    [else
     ; =>
     (response/xexpr
      #:preamble #"<!DOCTYPE html>"
      #:code     404
      #:message  #"Not found"
      `(html
        ,(generate-head-xexpr 
          #:title #"Not found")
        (body
         (p "Not found"))))]))
          
   
(define (handle-git-version-changes dir-path)
  ; if the git repository doesn't exist, create it:
  (when (not (directory-exists? (string-append dir-path "/.git")))
    
    ; TODO/WARNING/SECURITY: Injection attack vulnerability
    ; Need to verify that wikilink-name escapes path.
    
    (define git-init-cmd
      (string-append "git -C '" dir-path "' init;"
                     "git -C '" dir-path "' add content.md;"
                     "git -C '" dir-path "' commit -m 'Initial commit.'"))
    
    ($ git-init-cmd))
  
  ; commit changes:
  (define git-commit-cmd 
    (string-append "git -C '" dir-path "' add content.md;"
                   ; TODO: Let the user set the update comment.
                   "git -C '" dir-path "' commit -m 'Updated page.'"))
  
  ($ git-commit-cmd))


; Wiki-specific requests:

(define (handle-wiki-content-put-request req page)
  ; modifies the contents of the specified page.
  
  ; directory location:
  (define dir-path (string-append database-dir "/" (wikify-target page)))
  
  
  ; create the directory if it does not exist:
  (define created? #f)
  (when (not (directory-exists? dir-path))
    (set! created? #t)
    (make-directory dir-path))
  
  ; location of the markdown file:
  (define md-file-path (string-append dir-path "/" "content.md"))

  ; grab the new contents:
  (define post-data (request-post-data/raw req))
  
  (define param-string (bytes->string/utf-8 post-data))
  
  (define params (form-urlencoded->alist param-string))
                  
  (define contents (cdr (assq 'content params)))

  ; edit the content file:
  (call-with-output-file
   md-file-path
   #:exists 'replace 
   (λ (out)
     (write-string contents out)))
  
  ; Notify git of changes.
  (handle-git-version-changes dir-path)

  ; Render the page.
  (handle-wiki-view-request 
   req page 
   #:message (if created? "Page created." "Page edited.")))


    
; A handler to render the interface for editing a page:
(define (handle-wiki-edit-request req page)
  ; creates a page to allow editing.
  
  (define dir-path (string-append database-dir "/" page))
  (define md-file-path (string-append dir-path "/" "content.md"))
  
  (cond
    
    [(file-exists? md-file-path)
     ; =>
     (response/xexpr
      #:preamble #"<!DOCTYPE html>"
      `(html
        ,(generate-head-xexpr 
          #:title (string-append "edit: " page)
          #:style "

textarea#content {
  width: 50em;
  height: 30em;
}

")
        (body
         (form ((method "POST")
                (action "./"))
               (textarea
                ((id "content")
                 (name "content"))
                ,(file->string md-file-path))
               (br)
               (input ([type "submit"] [value "submit changes"]))))))]))


        

; A handler to render pages:
(define (handle-wiki-view-request req page
                                  #:message [message #f])
  
  ; directory containing page contents:
  (define dir-path (string-append database-dir "/" page))
  
  ; markdown file containing the page:
  (define md-file-path (string-append dir-path "/" "content.md"))

  (cond
    
    [(file-exists? md-file-path)
     (response
      200 #"OK"            ; code & message
      (current-seconds)    ; timestamp
      TEXT/HTML-MIME-TYPE  ; content type
      '()                  ; additional headers
      (λ (client-out)
                
        ; render the top:
        (write-bytes #"<!DOCTYPE>\n<html>\n" client-out)
        
        ; render the header:
        (define head (generate-head-xexpr 
                      #:title (string-append page " :: " uiki-name)))
        
        (write-string (xexpr->string head) client-out)
        
        ; render the body:
        (write-bytes #"<body>" client-out)
        
        ; enable MathJax for LaTeX support:
        (write-bytes #"<script type=\"text/x-mathjax-config\">
MathJax.Hub.Config({
  tex2jax: {inlineMath: [['$','$'], ['\\\\(','\\\\)']]}
});
</script>" client-out)
        (write-bytes #"<script src=\"https://cdn.mathjax.org/mathjax/latest/MathJax.js?config=TeX-AMS-MML_HTMLorMML\"></script>" client-out)
        
        ; Enable prettify for syntax highlighting:
        (write-bytes #"<script src=\"https://cdn.rawgit.com/google/code-prettify/master/loader/run_prettify.js\"></script>" client-out)
        
        ; Include a message, if any:
        (when message
          (write-string message client-out)
          (write-string "<hr />" client-out))
        
        ; Render the menu bar:
        (define wiki-top-bar 
          (string->bytes/utf-8 (string-append "
<p>
[<a href=\"/wiki/" (wikify-target page) "/edit\">edit</a>]
</p>
<hr />")))
        
        ; Render the menu bar:
        (write-bytes wiki-top-bar client-out)
        
        ; Pass content.md through through a markdown formatter, and then
        ; through the wikifier to convert wiki syntax:
        (match (process (string-append markdown-preprocess-command " " md-file-path " | " markdown-command))
          [(list in out exit err interrupt)
           ; Convert contents to wiki:
           (define wikified (apply string-append (wikify-text in)))
           
           (write-string wikified client-out)])
        
        ; Write the footer:
        (write-bytes #"</body>" client-out)
        
        (write-bytes #"</html>" client-out)))]
    
    ; Or, if the page is not found:
    [else  
     ; =>
     (response/xexpr
      #:preamble #"<!DOCTYPE html>"
      `(html
        ,(generate-head-xexpr
          #:title "page does not yet exist")
        (body
         (p "Page does not exist")
         (form ([method "POST"] [action ,(string-append "/wiki/" page)])
               (input ([type "hidden"] [name "content"] [value "Blank page"]))
               (input ([type "submit"] [value "Create page"]))))))]))


(define (handle-wiki-request req resource)
  ; handle a top level /wiki/ request:
  (when (equal? (last resource) "")
    (set! resource (reverse (cdr (reverse resource)))))
  
  (match resource
    ; view the page:
    [`(,page)
     #:when (equal? (request-method req) #"GET")
     (handle-wiki-view-request req page)]
    
    ; modify the page contents:
    [`(,page)
     #:when (equal? (request-method req) #"POST")
     (handle-wiki-content-put-request req page)]
    
    ; edit the page:
    [`(,page "edit")
     (handle-wiki-edit-request req page)]))
    
(define (start req)
  
  ; extract the uri from the request:
  (define uri (request-uri req))
  
  ; extract the path from the uri:
  (define path (map path/param-path (url-path uri)))
    
  ; The first element of the path determines the service;
  ; choices are "wiki" or "file":
  (define service (car path))
  
  (define resource (cdr path))
  
  (cond
    [(and auth-db-path (not (authenticated? auth-db-path req)))
     (response
      401 #"Unauthorized" 
      (current-seconds) 
      TEXT/HTML-MIME-TYPE
      (list
       (make-basic-auth-header
        "Authentication required"
        ))
      void)]
    
    [(equal? service "file")
     (handle-file-request req document-root resource)]
    
    [(equal? service "wiki")
     (handle-wiki-request req resource)]
  
    [else (response/xexpr
           #:preamble #"<!DOCTYPE html>"
           `(html 
             (head 
              (title "can't handle service: "  ,service)
             (body
              (p "Unhandled service type: " ,service)))))]))
 
(serve/servlet start
               #:port uiki-port
               #:servlet-path "/wiki/main"
               #:servlet-regexp #rx""
               #:launch-browser? #f
               #:ssl? use-ssl?
               #:ssl-cert ssl-cert-path
               #:ssl-key ssl-private-key-path
               #;end)


