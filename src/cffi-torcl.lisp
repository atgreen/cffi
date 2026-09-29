;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; cffi-torcl.lisp --- CFFI-SYS implementation for TorCL.
;;;
;;; Copyright (C) 2026, Anthony Green  <green@moxielogic.com>
;;;
;;; Permission is hereby granted, free of charge, to any person
;;; obtaining a copy of this software and associated documentation
;;; files (the "Software"), to deal in the Software without
;;; restriction, including without limitation the rights to use, copy,
;;; modify, merge, publish, distribute, sublicense, and/or sell copies
;;; of the Software, and to permit persons to whom the Software is
;;; furnished to do so, subject to the following conditions:
;;;
;;; The above copyright notice and this permission notice shall be
;;; included in all copies or substantial portions of the Software.
;;;
;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;;; NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
;;; HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
;;; WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
;;; DEALINGS IN THE SOFTWARE.
;;;

(in-package #:cffi-sys)

;;;
;;; TorCL's own foreign interface is TORCL-FFI.  Calls are made through
;;; TORCL-FFI:FOREIGN-CALL, which takes the return type, a list of argument
;;; types and a list of arguments, so this backend builds those lists rather
;;; than emitting a distinct alien stub per call site.  A variadic call passes
;;; the number of fixed arguments so the runtime can apply the C ABI rules for
;;; the variable part.  Structures by value are not part of this file: they go
;;; through TORCL-FFI:FOREIGN-CALL-BUFFERED, installed as CFFI's
;;; *FOREIGN-STRUCTURES-BY-VALUE* hook in cffi-torcl-fsbv.lisp.
;;;

;;;# Mis-features
;;;
;;; TorCL resolves a foreign symbol through the platform loader's default
;;; scope, so a symbol is not tied to the library option of its call site.
(pushnew 'flat-namespace *features*)

;;;# Symbol Case

(declaim (inline canonicalize-symbol-name-case))
(defun canonicalize-symbol-name-case (name)
  (declare (string name))
  (string-upcase name))

;;;# Foreign Types
;;;
;;; The type keywords TorCL uses for a scalar are not all spelled the way
;;; CFFI spells them, so translate explicitly instead of relying on names
;;; that happen to agree.  An unknown keyword is an error here rather than
;;; a call made with a type the runtime guessed at.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun torcl-type (type)
    "Return the TORCL-FFI type keyword for the canonical CFFI type TYPE."
    (case type
      (:char :char)
      (:unsigned-char :uchar)
      (:short :short)
      (:unsigned-short :ushort)
      (:int :int)
      (:unsigned-int :uint)
      (:long :long)
      (:unsigned-long :ulong)
      (:long-long :long-long)
      (:unsigned-long-long :unsigned-long-long)
      (:float :float)
      (:double :double)
      (:pointer :pointer)
      (:void :void)
      (t (error "~S is not a foreign type TorCL can pass or store." type)))))

(defun %foreign-type-size (type)
  "Return the size in bytes of a foreign type."
  (torcl-ffi:foreign-type-size (torcl-type type)))

(defun %foreign-type-alignment (type)
  "Return the alignment in bytes of a foreign type."
  (torcl-ffi:foreign-type-alignment (torcl-type type)))

;;;# Basic Pointer Operations

(deftype foreign-pointer ()
  ;; Name the predicate rather than aliasing TORCL-FFI:FOREIGN-POINTER: a
  ;; type that only names another DEFTYPE is not recognised by TorCL's
  ;; TYPEP (bliss-hfn71).
  '(satisfies pointerp))

(declaim (inline pointerp))
(defun pointerp (ptr)
  "Return true if PTR is a foreign pointer."
  (torcl-ffi:pointerp ptr))

(declaim (inline pointer-eq))
(defun pointer-eq (ptr1 ptr2)
  "Return true if PTR1 and PTR2 point to the same address."
  (torcl-ffi:pointer-eq ptr1 ptr2))

(declaim (inline null-pointer))
(defun null-pointer ()
  "Construct and return a null pointer."
  (torcl-ffi:null-pointer))

(declaim (inline null-pointer-p))
(defun null-pointer-p (ptr)
  "Return true if PTR is a null pointer."
  (torcl-ffi:null-pointer-p ptr))

(declaim (inline inc-pointer))
(defun inc-pointer (ptr offset)
  "Return a pointer pointing OFFSET bytes past PTR."
  (torcl-ffi:inc-pointer ptr offset))

(declaim (inline make-pointer))
(defun make-pointer (address)
  "Return a pointer pointing to ADDRESS."
  (torcl-ffi:make-pointer address))

(declaim (inline pointer-address))
(defun pointer-address (ptr)
  "Return the address pointed to by PTR."
  (torcl-ffi:pointer-address ptr))

;;;# Allocation
;;;
;;; TorCL tracks the allocations it owns: freeing one invalidates every
;;; pointer into it, and it bounds-checks accesses through them.  There is
;;; no foreign stack allocation, so WITH-FOREIGN-POINTER frees on exit.

(declaim (inline %foreign-alloc))
(defun %foreign-alloc (size)
  "Allocate SIZE bytes of foreign memory and return a pointer to it."
  (torcl-ffi:foreign-alloc size))

(declaim (inline foreign-free))
(defun foreign-free (ptr)
  "Free a pointer PTR allocated by %FOREIGN-ALLOC."
  (torcl-ffi:foreign-free ptr))

(defmacro with-foreign-pointer ((var size &optional size-var) &body body)
  "Bind VAR to SIZE bytes of foreign memory during BODY.  The pointer
in VAR is invalid beyond the dynamic extent of BODY.  If SIZE-VAR is
supplied, it will be bound to SIZE during BODY."
  (unless size-var
    (setf size-var (gensym "SIZE")))
  `(let* ((,size-var ,size)
          (,var (%foreign-alloc ,size-var)))
     (declare (ignorable ,size-var))
     (unwind-protect
          (progn ,@body)
       (foreign-free ,var))))

;;;# Shareable Vectors
;;;
;;; TorCL does not pin a Lisp vector for C, so WITH-POINTER-TO-VECTOR-DATA
;;; copies the elements into foreign storage and copies them back when BODY
;;; returns, including on a nonlocal exit.  The pointer is dead afterwards.

(declaim (inline make-shareable-byte-vector))
(defun make-shareable-byte-vector (size)
  "Create a Lisp vector of SIZE bytes that can be passed to
WITH-POINTER-TO-VECTOR-DATA."
  ;; TorCL leaves an uninitialised specialised array full of NIL, which is
  ;; not a byte the copy to foreign storage can marshal (bliss-ccta2).
  (make-array size :element-type '(unsigned-byte 8) :initial-element 0))

(defmacro with-pointer-to-vector-data ((ptr-var vector) &body body)
  "Bind PTR-VAR to a foreign pointer to the data in VECTOR."
  `(torcl-ffi:with-pointer-to-vector-data (,ptr-var ,vector :unsigned-char)
     ,@body))

;;;# Dereferencing

(defun %mem-ref (ptr type &optional (offset 0))
  "Dereference an object of TYPE OFFSET bytes from PTR."
  (torcl-ffi:mem-ref ptr (torcl-type type) offset))

(defun %mem-set (value ptr type &optional (offset 0))
  "Set an object of TYPE OFFSET bytes from PTR to VALUE."
  (torcl-ffi:mem-set value ptr (torcl-type type) offset)
  value)

;;; When the type is known at compile time, name the TorCL type then
;;; instead of on every access.
(define-compiler-macro %mem-ref (&whole form ptr type &optional (offset 0))
  (if (constant-form-p type)
      `(torcl-ffi:mem-ref ,ptr ,(torcl-type (constant-form-value type)) ,offset)
      form))

(define-compiler-macro %mem-set (&whole form value ptr type &optional (offset 0))
  (if (constant-form-p type)
      (once-only (value)
        `(progn
           (torcl-ffi:mem-set ,value ,ptr
                              ,(torcl-type (constant-form-value type))
                              ,offset)
           ,value))
      form))

;;;# Foreign Symbols
;;;
;;; A lookup goes through the loader's default scope unless CFFI hands us
;;; the handle of the library to search.  Resolved addresses are cached
;;; because a call site resolves its symbol on every call; closing a
;;; library retires the cache, since its symbols are gone with it.

(defvar *symbol-pointer-cache* (make-hash-table :test 'equal)
  "Foreign symbol name -> pointer, for symbols found in the default scope.")

(defun %foreign-symbol-pointer (name library)
  "Returns a pointer to a foreign symbol NAME, or NIL if it is not found."
  (let ((scope (unless (or (null library) (eq library :default)) library)))
    (handler-case (torcl-ffi:foreign-symbol-pointer name scope)
      (torcl-ffi:ffi-error () nil))))

(defun foreign-function-pointer (name)
  "Return a pointer to the foreign function NAME, signalling an error if
no such symbol is defined."
  (declare (string name))
  (or (gethash name *symbol-pointer-cache*)
      (let ((pointer (%foreign-symbol-pointer name :default)))
        (unless pointer
          (error "Undefined foreign function: ~S" name))
        (setf (gethash name *symbol-pointer-cache*) pointer))))

;;;# Calling Foreign Functions
;;;
;;; ARGS is CFFI's flat (type value type value ... return-type) list.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun foreign-funcall-parse-args (args)
    "Return three values: the TorCL argument types, the argument forms and
the TorCL return type of the call described by ARGS."
    (let ((return-type :void)
          (types '())
          (values '()))
      ;; A trailing type with no value after it is the return type; every
      ;; other element is a type paired with the form for its argument.
      (loop for rest on args by #'cddr
            do (if (cdr rest)
                   (progn (push (torcl-type (first rest)) types)
                          (push (second rest) values))
                   (setf return-type (torcl-type (first rest)))))
      (values (nreverse types) (nreverse values) return-type)))

  (defun check-calling-convention (convention)
    "TorCL's targets have a single C calling convention."
    (unless (member convention '(nil :cdecl :default))
      (error "TorCL does not support the ~S calling convention." convention))))

;;; A call form: the function pointer comes either from a symbol name or
;;; from a pointer the caller already has.
(defmacro %%foreign-funcall (function-form args &optional fixed-count)
  (multiple-value-bind (types values return-type)
      (foreign-funcall-parse-args args)
    (let ((call `(torcl-ffi:foreign-call ,function-form ,return-type ',types
                                         (list ,@values)
                                         ,@(when fixed-count
                                             (list fixed-count)))))
      ;; A C function returning void returns no value at all.
      (if (eq return-type :void)
          `(progn ,call (values))
          call))))

(defmacro %foreign-funcall (name args &key library convention)
  "Call the foreign function NAME with ARGS."
  (declare (ignore library))
  (check-calling-convention convention)
  `(%%foreign-funcall (foreign-function-pointer ,name) ,args))

(defmacro %foreign-funcall-pointer (ptr args &key convention)
  "Call the foreign function at PTR with ARGS."
  (check-calling-convention convention)
  `(%%foreign-funcall ,ptr ,args))

;;; The variadic forms keep the fixed argument count, which the runtime
;;; needs to apply the ABI's rules to the variable arguments.  CFFI has
;;; already promoted the types of the variable part.
(defmacro %foreign-funcall-varargs (name fixed-args varargs
                                    &key library convention)
  (declare (ignore library))
  (check-calling-convention convention)
  `(%%foreign-funcall (foreign-function-pointer ,name)
                      ,(append fixed-args varargs)
                      ,(floor (length fixed-args) 2)))

(defmacro %foreign-funcall-pointer-varargs (ptr fixed-args varargs
                                            &key convention)
  (check-calling-convention convention)
  `(%%foreign-funcall ,ptr ,(append fixed-args varargs)
                      ,(floor (length fixed-args) 2)))

;;;# Callbacks
;;;
;;; CFFI requires that redefining a callback keep the pointer C already
;;; holds, so a name's foreign entry is created once and dispatches through
;;; the function currently registered for that name.  A redefinition that
;;; changes the signature needs a new entry, and the old one stays alive:
;;; C may still be holding it, and freeing it under C is not recoverable.

(defvar *callback-functions* (make-hash-table :test 'eq)
  "Callback name -> the Lisp function that name currently stands for.")

(defvar *callbacks* (make-hash-table :test 'eq)
  "Callback name -> (TorCL callback . signature) serving that name.")

(defun %register-callback (name trampoline return-type argument-types)
  "Ensure NAME has a foreign entry with the given signature, and return it.
TRAMPOLINE is called with the foreign arguments; it looks up NAME's current
function, so a redefinition does not need a new entry."
  (let ((signature (cons return-type argument-types))
        (existing (gethash name *callbacks*)))
    (if (and existing (equal (cdr existing) signature))
        (car existing)
        ;; A previous entry with a different signature is deliberately not
        ;; freed: C may still call it, and its Lisp side now errors.
        (car (setf (gethash name *callbacks*)
                   (cons (torcl-ffi:make-callback
                          trampoline
                          (torcl-type return-type)
                          (mapcar #'torcl-type argument-types))
                         signature))))))

(defmacro %defcallback (name return-type arg-names arg-types body
                        &key convention)
  (check-calling-convention convention)
  `(progn
     (setf (gethash ',name *callback-functions*)
           (lambda (,@arg-names) ,body))
     (%register-callback ',name
                         (lambda (,@arg-names)
                           (funcall (gethash ',name *callback-functions*)
                                    ,@arg-names))
                         ',return-type ',arg-types)
     (%callback ',name)))

(defun %callback (name)
  "Return a pointer to the foreign entry of the callback NAME."
  (let ((callback (car (gethash name *callbacks*))))
    (unless callback
      (error "Undefined callback: ~S" name))
    (torcl-ffi:callback-pointer callback)))

;;;# Loading and Closing Foreign Libraries

(defun %load-foreign-library (name path)
  "Load a foreign library from PATH and return its handle."
  (declare (ignore name))
  (clrhash *symbol-pointer-cache*)
  (torcl-ffi:load-foreign-library path))

(defun %close-foreign-library (handle)
  "Close a foreign library, invalidating pointers to its symbols."
  (clrhash *symbol-pointer-cache*)
  (torcl-ffi:close-foreign-library handle))

(defun native-namestring (pathname)
  (namestring pathname))
