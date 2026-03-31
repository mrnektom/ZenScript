package org.zenscript.intellij.psi

import com.intellij.openapi.project.Project
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFileFactory
import org.zenscript.intellij.ZenScriptFileType

object ZenScriptPsiFactory {
    fun createIdentifier(project: Project, name: String): PsiElement? {
        val file = PsiFileFactory.getInstance(project)
            .createFileFromText("dummy.zs", ZenScriptFileType, "let $name = 0")
        // Navigate: file -> VAR_DECLARATION -> IDENTIFIER
        val varDecl = file.firstChild ?: return null
        return varDecl.node.findChildByType(ZenScriptTokenTypes.IDENTIFIER)?.psi
    }
}
