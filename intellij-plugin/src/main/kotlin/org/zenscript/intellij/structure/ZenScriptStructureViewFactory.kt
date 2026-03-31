package org.zenscript.intellij.structure

import com.intellij.ide.structureView.*
import com.intellij.ide.structureView.impl.common.PsiTreeElementBase
import com.intellij.ide.util.treeView.smartTree.Sorter
import com.intellij.lang.PsiStructureViewFactory
import com.intellij.openapi.editor.Editor
import com.intellij.psi.PsiFile
import org.zenscript.intellij.ZenScriptFile
import org.zenscript.intellij.ZenScriptIcons
import org.zenscript.intellij.psi.*
import javax.swing.Icon

class ZenScriptStructureViewFactory : PsiStructureViewFactory {
    override fun getStructureViewBuilder(psiFile: PsiFile): StructureViewBuilder? {
        if (psiFile !is ZenScriptFile) return null
        return object : TreeBasedStructureViewBuilder() {
            override fun createStructureViewModel(editor: Editor?): StructureViewModel {
                return ZenScriptStructureViewModel(psiFile)
            }
        }
    }
}

private class ZenScriptStructureViewModel(file: ZenScriptFile) :
    StructureViewModelBase(file, ZenScriptFileStructureViewElement(file)),
    StructureViewModel.ElementInfoProvider {

    override fun getSorters(): Array<Sorter> = arrayOf(Sorter.ALPHA_SORTER)
    override fun isAlwaysShowsPlus(element: StructureViewTreeElement): Boolean = false
    override fun isAlwaysLeaf(element: StructureViewTreeElement): Boolean {
        val value = (element as? PsiTreeElementBase<*>)?.value
        return value !is ZenScriptStructDeclaration && value !is ZenScriptEnumDeclaration
    }
}

private class ZenScriptFileStructureViewElement(private val file: ZenScriptFile) :
    PsiTreeElementBase<ZenScriptFile>(file) {

    override fun getPresentableText(): String? = file.name

    override fun getChildrenBase(): Collection<StructureViewTreeElement> {
        val result = mutableListOf<StructureViewTreeElement>()
        for (child in file.children) {
            if (child is ZenScriptNamedElement) {
                result.add(ZenScriptDeclarationStructureViewElement(child))
            }
        }
        return result
    }
}

private class ZenScriptDeclarationStructureViewElement(
    private val element: ZenScriptNamedElement
) : PsiTreeElementBase<ZenScriptNamedElement>(element) {

    override fun getPresentableText(): String {
        val kind = when (element) {
            is ZenScriptFnDeclaration -> "fn"
            is ZenScriptStructDeclaration -> "struct"
            is ZenScriptEnumDeclaration -> "enum"
            is ZenScriptVarDeclaration -> "let"
            else -> ""
        }
        return "$kind ${element.name ?: "?"}"
    }

    override fun getIcon(open: Boolean): Icon = ZenScriptIcons.FILE

    override fun getChildrenBase(): Collection<StructureViewTreeElement> {
        val result = mutableListOf<StructureViewTreeElement>()
        for (child in element.children) {
            if (child is ZenScriptNamedElement) {
                result.add(ZenScriptDeclarationStructureViewElement(child))
            }
        }
        return result
    }
}
