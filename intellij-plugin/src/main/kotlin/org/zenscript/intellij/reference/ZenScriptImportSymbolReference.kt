package org.zenscript.intellij.reference

import com.intellij.openapi.util.TextRange
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiReferenceBase
import org.zenscript.intellij.psi.ZenScriptExportFromStatement
import org.zenscript.intellij.psi.ZenScriptImportStatement
import org.zenscript.intellij.psi.ZenScriptEnumDeclaration
import org.zenscript.intellij.psi.ZenScriptImportSymbol
import org.zenscript.intellij.psi.ZenScriptUseStatement

class ZenScriptImportSymbolReference(element: ZenScriptImportSymbol) :
    PsiReferenceBase<ZenScriptImportSymbol>(element, calculateRange(element)) {

    companion object {
        private fun calculateRange(element: ZenScriptImportSymbol): TextRange {
            // Range covers the original name (first identifier)
            val originalName = element.getOriginalName() ?: return TextRange(0, element.textLength)
            val text = element.text
            val start = text.indexOf(originalName)
            return if (start >= 0) TextRange(start, start + originalName.length) else TextRange(0, element.textLength)
        }
    }

    override fun resolve(): PsiElement? {
        val parent = element.parent
        val originalName = element.getOriginalName() ?: return null

        return when (parent) {
            is ZenScriptImportStatement -> {
                val path = parent.getPath() ?: return null
                val targetFile = ZenScriptResolveUtil.resolveImportPath(element, path) ?: return null
                ZenScriptResolveUtil.findExportedSymbol(targetFile, originalName)
            }
            is ZenScriptExportFromStatement -> {
                val path = parent.getPath() ?: return null
                val targetFile = ZenScriptResolveUtil.resolveImportPath(element, path) ?: return null
                ZenScriptResolveUtil.findExportedSymbol(targetFile, originalName)
            }
            is ZenScriptUseStatement -> {
                val enumName = parent.getEnumName() ?: return null
                val enumDecl = ZenScriptResolveUtil.resolveInScope(element, enumName) ?: return null
                if (enumDecl is ZenScriptEnumDeclaration) {
                    ZenScriptResolveUtil.findEnumVariant(enumDecl, originalName)
                } else {
                    null
                }
            }
            else -> null
        }
    }

    override fun getVariants(): Array<Any> = emptyArray()
}
