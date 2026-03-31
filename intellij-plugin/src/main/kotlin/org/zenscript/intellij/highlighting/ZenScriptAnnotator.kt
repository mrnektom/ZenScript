package org.zenscript.intellij.highlighting

import com.intellij.lang.annotation.AnnotationHolder
import com.intellij.lang.annotation.Annotator
import com.intellij.lang.annotation.HighlightSeverity
import com.intellij.openapi.editor.colors.TextAttributesKey
import com.intellij.psi.PsiElement
import org.zenscript.intellij.psi.ZenScriptFnDeclaration
import org.zenscript.intellij.psi.ZenScriptReferenceExpression
import org.zenscript.intellij.psi.ZenScriptStructField
import org.zenscript.intellij.psi.ZenScriptTokenTypes

class ZenScriptAnnotator : Annotator {
    override fun annotate(element: PsiElement, holder: AnnotationHolder) {
        when (element) {
            is ZenScriptFnDeclaration -> highlightNameIdentifier(element, holder, ZenScriptSyntaxHighlighter.FUNCTION_NAME)
            is ZenScriptStructField -> highlightNameIdentifier(element, holder, ZenScriptSyntaxHighlighter.FIELD_NAME)
            is ZenScriptReferenceExpression -> annotateReference(element, holder)
        }
    }

    private fun highlightNameIdentifier(element: PsiElement, holder: AnnotationHolder, key: TextAttributesKey) {
        val nameNode = element.node.findChildByType(ZenScriptTokenTypes.IDENTIFIER) ?: return
        holder.newSilentAnnotation(HighlightSeverity.INFORMATION)
            .range(nameNode.psi)
            .textAttributes(key)
            .create()
    }

    private fun annotateReference(element: ZenScriptReferenceExpression, holder: AnnotationHolder) {
        val resolved = element.reference.resolve() ?: return
        val identifierNode = element.node.findChildByType(ZenScriptTokenTypes.IDENTIFIER) ?: return

        val key = when (resolved) {
            is ZenScriptFnDeclaration -> ZenScriptSyntaxHighlighter.FUNCTION_CALL
            is ZenScriptStructField -> ZenScriptSyntaxHighlighter.FIELD_NAME
            else -> return
        }

        holder.newSilentAnnotation(HighlightSeverity.INFORMATION)
            .range(identifierNode.psi)
            .textAttributes(key)
            .create()
    }
}
