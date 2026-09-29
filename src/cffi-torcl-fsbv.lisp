;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; cffi-torcl-fsbv.lisp --- Structures by value on TorCL.
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

(in-package #:cffi)

;;;
;;; TorCL passes and returns aggregates through
;;; TORCL-FFI:FOREIGN-CALL-BUFFERED, which takes the address of each
;;; argument and the address of storage for the result, and applies the
;;; target ABI's aggregate rules itself.  That replaces what cffi-libffi
;;; does elsewhere, so a TorCL image needs neither libffi nor a C compiler
;;; to call a function that takes or returns a structure by value.
;;;
;;; The runtime lays a structure out itself from a description of its
;;; fields, so the description this file builds is checked against the
;;; layout CFFI computed: same size, same alignment, same field offsets.
;;; A structure whose slots CFFI placed somewhere else — an explicit
;;; :OFFSET or :SIZE, for instance — is reported instead of called, since
;;; inserting padding fields to make the offsets agree would change how
;;; the ABI classifies the structure and quietly call it wrongly.
;;;

(define-condition torcl-aggregate-error (cffi-error simple-error) ()
  (:documentation "Signalled when TorCL cannot describe a foreign
aggregate type to its ABI layer."))

(defun torcl-aggregate-error (format-control &rest format-arguments)
  (error 'torcl-aggregate-error
         :format-control format-control
         :format-arguments format-arguments))

;;;# Describing a type to the runtime

(defun torcl-slot-count (slot)
  "The number of consecutive elements SLOT holds."
  (if (typep slot 'aggregate-struct-slot)
      (slot-count slot)
      1))

(defun torcl-type-descriptor (type)
  "Return the TORCL-FFI type descriptor for the CFFI type TYPE.

Scalars and pointers are keywords; a structure or union is a list of its
fields.  An array becomes its elements in order: the ABI classifies an
array by its elements, and the runtime has no array descriptor."
  (let ((parsed (ensure-parsed-base-type type)))
    (typecase parsed
      (foreign-union-type
       (list* :union (mapcar (lambda (slot)
                               (torcl-slot-descriptor slot parsed))
                             (slots-in-order parsed))))
      (foreign-struct-type
       (torcl-struct-descriptor parsed))
      (foreign-array-type
       (let ((element (torcl-type-descriptor (element-type parsed)))
             (count (reduce #'* (dimensions parsed))))
         (if (= count 1)
             element
             (list* :struct (make-list count :initial-element element)))))
      (t (cffi-sys::torcl-type (canonicalize parsed))))))

(defun torcl-slot-descriptor (slot struct-type)
  "The descriptor for one element of SLOT, checked for describability."
  (handler-case (torcl-type-descriptor (slot-type slot))
    (error (error)
      (torcl-aggregate-error
       "Cannot describe slot ~S of ~S to TorCL's ABI layer: ~A"
       (slot-name slot) (unparse-type struct-type) error))))

(defun torcl-struct-descriptor (type)
  "Describe the structure TYPE as a TORCL-FFI descriptor, or signal a
TORCL-AGGREGATE-ERROR if the runtime would lay it out differently than
CFFI did."
  (let ((fields '())
        (offset 0))
    (dolist (slot (slots-in-order type))
      (let* ((descriptor (torcl-slot-descriptor slot type))
             (count (torcl-slot-count slot))
             (size (torcl-ffi:foreign-type-size descriptor))
             (alignment (torcl-ffi:foreign-type-alignment descriptor))
             (natural (* alignment (ceiling offset alignment))))
        (unless (= natural (slot-offset slot))
          (torcl-aggregate-error
           "Slot ~S of ~S is at offset ~D, but TorCL's ABI layer puts it ~
            at ~D.  TorCL cannot pass or return this type by value."
           (slot-name slot) (unparse-type type) (slot-offset slot) natural))
        (dotimes (i count)
          (push descriptor fields))
        (setf offset (+ natural (* count size)))))
    (let ((descriptor (list* :struct (nreverse fields))))
      (check-torcl-layout descriptor type)
      descriptor)))

(defun check-torcl-layout (descriptor type)
  "Signal a TORCL-AGGREGATE-ERROR unless DESCRIPTOR has the size and
alignment CFFI computed for TYPE."
  (let ((size (torcl-ffi:foreign-type-size descriptor))
        (alignment (torcl-ffi:foreign-type-alignment descriptor)))
    (unless (and (= size (foreign-type-size type))
                 (= alignment (foreign-type-alignment type)))
      (torcl-aggregate-error
       "~S is ~D byte~:P aligned to ~D for CFFI, but ~D byte~:P aligned ~
        to ~D for TorCL's ABI layer.  TorCL cannot pass or return this ~
        type by value."
       (unparse-type type) (foreign-type-size type)
       (foreign-type-alignment type) size alignment))))

;;;# Call plans
;;;
;;; Describing a signature means consing and checking a layout, so the
;;; result is kept, keyed by the signature itself.  Two threads racing to
;;; describe the same signature may both build it and one store wins;
;;; plans are values, so that costs work and nothing else.

(defvar *torcl-call-plans* (make-hash-table :test 'equal)
  "Signature (return-type . argument-types) -> (return-descriptor
. argument-descriptors).")

(defun torcl-call-plan (return-type argument-types)
  "The TORCL-FFI descriptors for a call returning RETURN-TYPE and taking
ARGUMENT-TYPES."
  (let ((signature (cons return-type argument-types)))
    (or (gethash signature *torcl-call-plans*)
        (setf (gethash signature *torcl-call-plans*)
              (cons (if (eql return-type :void)
                        :void
                        (torcl-type-descriptor return-type))
                    (mapcar #'torcl-type-descriptor argument-types))))))

;;;# The call itself

(defun translate-objects-ret (symbols function-arguments types return-type
                              call-form)
  "Like TRANSLATE-OBJECTS, for a call whose result arrives in foreign
storage: a built-in return type is read back here, since
EXPAND-FROM-FOREIGN will not do it for us."
  (translate-objects
   symbols
   function-arguments
   types
   return-type
   (if (or (eql return-type :void)
           (typep (parse-type return-type) 'translatable-foreign-type))
       call-form
       `(mem-ref ,call-form ',(canonicalize-foreign-type return-type)))
   t))

(defun foreign-funcall-form/fsbv-with-torcl (function function-arguments
                                            symbols types return-type
                                            argument-types
                                            &optional pointerp)
  "A body for FOREIGN-FUNCALL that calls FUNCTION through TorCL's
aggregate call interface.  Every argument is passed by address, which is
what TRANSLATE-OBJECTS-RET's indirect translation produces."
  (let ((function-form (if pointerp
                           function
                           `(cffi-sys::foreign-function-pointer ,function))))
    (if (eql return-type :void)
        (translate-objects-ret
         symbols function-arguments types return-type
         `(let ((plan (torcl-call-plan ',return-type ',argument-types)))
            (torcl-ffi:foreign-call-buffered ,function-form (car plan)
                                             (cdr plan) (list ,@symbols)
                                             (null-pointer))
            (values)))
        `(with-foreign-object (result ',return-type)
           ,(translate-objects-ret
             symbols function-arguments types return-type
             `(let ((plan (torcl-call-plan ',return-type ',argument-types)))
                (torcl-ffi:foreign-call-buffered ,function-form (car plan)
                                                 (cdr plan) (list ,@symbols)
                                                 result)))))))

(setf *foreign-structures-by-value* 'foreign-funcall-form/fsbv-with-torcl)
