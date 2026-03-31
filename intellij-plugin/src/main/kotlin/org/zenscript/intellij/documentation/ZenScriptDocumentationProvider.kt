package org.zenscript.intellij.documentation

import com.intellij.lang.documentation.AbstractDocumentationProvider
import com.intellij.openapi.util.text.StringUtil
import com.intellij.psi.PsiElement
import org.zenscript.intellij.psi.*

class ZenScriptDocumentationProvider : AbstractDocumentationProvider() {
    override fun generateDoc(element: PsiElement, originalElement: PsiElement?): String? {
        if (element !is ZenScriptNamedElement) return null
        val signature = getDeclarationSignature(element) ?: return null
        return "<pre>${StringUtil.escapeXmlEntities(signature)}</pre>"
    }

    override fun getQuickNavigateInfo(element: PsiElement, originalElement: PsiElement?): String? {
        if (element !is ZenScriptNamedElement) return null
        return getDeclarationSignature(element)
    }

    private fun getDeclarationSignature(element: ZenScriptNamedElement): String? {
        val node = element.node
        val text = node.text

        return when (element) {
            is ZenScriptFnDeclaration -> {
                // Show up to the opening brace or = (the signature, not the body)
                val braceIdx = text.indexOf('{')
                val eqIdx = text.indexOf('=')
                val endIdx = when {
                    braceIdx >= 0 && eqIdx >= 0 -> minOf(braceIdx, eqIdx)
                    braceIdx >= 0 -> braceIdx
                    eqIdx >= 0 -> eqIdx
                    else -> text.length
                }
                text.substring(0, endIdx).trim()
            }
            is ZenScriptVarDeclaration -> {
                // Show "let/const name: Type" without the initializer body (keep short)
                val eqIdx = text.indexOf('=')
                if (eqIdx >= 0) {
                    val afterEq = text.substring(eqIdx + 1).trim()
                    // If initializer is short (< 40 chars), include it
                    if (afterEq.length <= 40) text.trim() else text.substring(0, eqIdx).trim()
                } else {
                    text.trim()
                }
            }
            is ZenScriptStructDeclaration -> {
                // Show "struct Name { fields }" — full text for short structs
                if (text.length <= 80) text.trim() else {
                    val braceIdx = text.indexOf('{')
                    if (braceIdx >= 0) text.substring(0, braceIdx).trim() + " { ... }" else text.trim()
                }
            }
            is ZenScriptEnumDeclaration -> {
                if (text.length <= 80) text.trim() else {
                    val braceIdx = text.indexOf('{')
                    if (braceIdx >= 0) text.substring(0, braceIdx).trim() + " { ... }" else text.trim()
                }
            }
            is ZenScriptParameter -> {
                text.trim()
            }
            is ZenScriptStructField -> {
                text.trim()
            }
            else -> null
        }
    }
}
