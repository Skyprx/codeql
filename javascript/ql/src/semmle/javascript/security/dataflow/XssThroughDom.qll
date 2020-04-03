/**
 * Provides a taint-tracking configuration for reasoning about
 * cross-site scripting vulnerabilities through the DOM.
 */

import javascript

/**
 * Classes and predicates for the XSS through DOM query.
 */
module XssThroughDom {
  import Xss::XssThroughDom
  private import semmle.javascript.security.dataflow.Xss::DomBasedXss as DomBasedXss
  private import semmle.javascript.dataflow.InferredTypes

  /**
   * A taint-tracking configuration for reasoning about XSS through the DOM.
   */
  class Configuration extends TaintTracking::Configuration {
    Configuration() { this = "XssThroughDOM" }

    override predicate isSource(DataFlow::Node source) { source instanceof Source }

    override predicate isSink(DataFlow::Node sink) { sink instanceof DomBasedXss::Sink }

    override predicate isSanitizer(DataFlow::Node node) {
      super.isSanitizer(node) or
      node instanceof DomBasedXss::Sanitizer
    }

    override predicate isSanitizerGuard(TaintTracking::SanitizerGuardNode guard) {
      guard instanceof TypeTestGuard or
      guard instanceof HasNodePropertySanitizerGuard
    }
  }

  /**
   * Gets an attribute name that could store user controlled data.
   *
   * Attributes such as "id", "href", and "src" are often used as input to HTML.
   * However, they are either rarely controlable by a user, or already a sink for other XSS vulnerabilities.
   * Such attributes are therefore ignored.
   */
  bindingset[result]
  string unsafeAttributeName() {
    result.regexpMatch("data-.*") or
    result = ["name", "value"]
  }

  /**
   * A source for text from the DOM from a JQuery method call.
   */
  class JQueryTextSource extends Source, JQuery::MethodCall {
    JQueryTextSource() {
      (
        this.getMethodName() = ["text", "val"] and this.getNumArgument() = 0
        or
        this.getMethodName() = "attr" and
        this.getNumArgument() = 1 and
        forex(InferredType t | t = this.getArgument(0).analyze().getAType() | t = TTString()) and
        this.getArgument(0).mayHaveStringValue(unsafeAttributeName())
      ) and
      // looks like a $("<p>" + ... ) source, which is benign for this query.
      not this
          .getReceiver()
          .(DataFlow::CallNode)
          .getAnArgument()
          .(StringOps::ConcatenationRoot)
          .getConstantStringParts()
          .substring(0, 1) = "<"
    }
  }

  /**
   * A source for text from the DOM from a DOM property read or call to `getAttribute()`.
   */
  class DOMTextSource extends Source {
    DOMTextSource() {
      exists(DataFlow::PropRead read | read = this |
        read.getBase().getALocalSource() = DOM::domValueRef() and
        exists(string propName | propName = ["innerText", "textContent", "value", "name"] |
          read.getPropertyName() = propName or
          read.getPropertyNameExpr().flow().mayHaveStringValue(propName)
        )
      )
      or
      exists(DataFlow::MethodCallNode mcn | mcn = this |
        mcn.getReceiver().getALocalSource() = DOM::domValueRef() and
        mcn.getMethodName() = "getAttribute" and
        mcn.getArgument(0).mayHaveStringValue(unsafeAttributeName())
      )
    }
  }

  /**
   * A test of form `typeof x === "something"`, preventing `x` from being a string in some cases.
   *
   * This sanitizer helps prune infeasible paths in type-overloaded functions.
   */
  class TypeTestGuard extends TaintTracking::SanitizerGuardNode, DataFlow::ValueNode {
    override EqualityTest astNode;
    TypeofExpr typeof;
    boolean polarity;

    TypeTestGuard() {
      astNode.getAnOperand() = typeof and
      (
        // typeof x === "string" sanitizes `x` when it evaluates to false
        astNode.getAnOperand().getStringValue() = "string" and
        polarity = astNode.getPolarity().booleanNot()
        or
        // typeof x === "object" sanitizes `x` when it evaluates to true
        astNode.getAnOperand().getStringValue() != "string" and
        polarity = astNode.getPolarity()
      )
    }

    override predicate sanitizes(boolean outcome, Expr e) {
      polarity = outcome and
      e = typeof.getOperand()
    }
  }

  /**
   * The precense of a `nodeType` or `jquery` property indicates that the value is a DOM node, and not the text of a DOM node.
   *
   * This sanitizer helps prune infeasible paths in type-overloaded functions.
   */
  class HasNodePropertySanitizerGuard extends TaintTracking::SanitizerGuardNode {
    DataFlow::PropRead read;

    HasNodePropertySanitizerGuard() {
      read = this and
      read.getPropertyName() = ["nodeType", "jquery"]
    }

    override predicate sanitizes(boolean outcome, Expr e) {
      e = read.getBase().asExpr() and outcome = true
    }
  }
}
