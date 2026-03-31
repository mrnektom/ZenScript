package org.zenscript.intellij.reference

import com.intellij.openapi.util.TextRange
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiReferenceBase
import org.zenscript.intellij.psi.ZenScriptImportPath
import org.zenscript.intellij.psi.ZenScriptTokenTypes

class ZenScriptImportPathReference(element: ZenScriptImportPath) :
    PsiReferenceBase<ZenScriptImportPath>(element, calculateRange(element)) {

    companion object {
        private fun calculateRange(element: ZenScriptImportPath): TextRange {
            // Range covers text inside quotes (skip the quote characters)
            val stringNode = element.node.findChildByType(ZenScriptTokenTypes.STRING_LITERAL)
            if (stringNode != null) {
                val offset = stringNode.startOffset - element.node.startOffset
                val len = stringNode.textLength
                // Skip opening and closing quote
                return if (len >= 2) TextRange(offset + 1, offset + len - 1) else TextRange(0, element.textLength)
            }
            return TextRange(0, element.textLength)
        }
    }

    override fun resolve(): PsiElement? {
        val path = element.getPathString() ?: return null
        return ZenScriptResolveUtil.resolveImportPath(element, path)
    }

    override fun getVariants(): Array<Any> {
        val containingFile = element.containingFile?.virtualFile ?: return emptyArray()
        val dir = containingFile.parent ?: return emptyArray()
        return dir.children
            .filter { it.extension == "zs" && it != containingFile }
            .map { "./${it.name}" }
            .toTypedArray()
    }
}
