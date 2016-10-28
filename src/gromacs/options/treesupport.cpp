/*
 * This file is part of the GROMACS molecular simulation package.
 *
 * Copyright (c) 2016, by the GROMACS development team, led by
 * Mark Abraham, David van der Spoel, Berk Hess, and Erik Lindahl,
 * and including many others, as listed in the AUTHORS file in the
 * top-level source directory and at http://www.gromacs.org.
 *
 * GROMACS is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * as published by the Free Software Foundation; either version 2.1
 * of the License, or (at your option) any later version.
 *
 * GROMACS is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with GROMACS; if not, see
 * http://www.gnu.org/licenses, or write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA.
 *
 * If you want to redistribute modifications to GROMACS, please
 * consider that scientific software is very special. Version
 * control is crucial - bugs must be traceable. We will be happy to
 * consider code for inclusion in the official distribution, but
 * derived work must not be called official GROMACS. Details are found
 * in the README & COPYING files - if they are missing, get the
 * official version at http://www.gromacs.org.
 *
 * To help us fund GROMACS development, we humbly ask that you cite
 * the research papers on the package. Check out http://www.gromacs.org.
 */
/*! \internal \file
 * \brief
 * Implements functions from treesupport.h.
 *
 * \author Teemu Murtola <teemu.murtola@gmail.com>
 * \ingroup module_options
 */
#include "gmxpre.h"

#include "treesupport.h"

#include "gromacs/options/options.h"
#include "gromacs/options/optionsassigner.h"
#include "gromacs/options/optionsection.h"
#include "gromacs/options/optionsvisitor.h"
#include "gromacs/utility/exceptions.h"
#include "gromacs/utility/ikeyvaluetreeerror.h"
#include "gromacs/utility/keyvaluetree.h"
#include "gromacs/utility/keyvaluetreebuilder.h"

namespace gmx
{

namespace
{

class TreeAssignHelper
{
    public:
        TreeAssignHelper(Options *options, IKeyValueTreeErrorHandler *errorHandler)
            : assigner_(options), errorHandler_(errorHandler)
        {
            if (errorHandler_ == nullptr)
            {
                errorHandler_ = defaultKeyValueTreeErrorHandler();
            }
        }

        void assignAll(const KeyValueTreeObject &root)
        {
            assigner_.start();
            assignSubTree(root);
            assigner_.finish();
        }

    private:
        void assignSubTree(const KeyValueTreeObject &tree)
        {
            // TODO: Use the error handler also in other case.
            for (const KeyValueTreeProperty &prop : tree.properties())
            {
                context_.append(prop.key());
                if (prop.value().isArray())
                {
                    assignArray(prop.key(), prop.value().asArray());
                }
                else if (prop.value().isObject())
                {
                    assigner_.startSection(prop.key().c_str());
                    assignSubTree(prop.value().asObject());
                    assigner_.finishSection();
                }
                else
                {
                    assigner_.startOption(prop.key().c_str());
                    try
                    {
                        assigner_.appendValue(prop.value().asVariant());
                    }
                    catch (UserInputError &ex)
                    {
                        if (!errorHandler_->onError(&ex, context_))
                        {
                            throw;
                        }
                    }
                    assigner_.finishOption();
                }
                context_.pop_back();
            }
        }

        void assignArray(const std::string       &key,
                         const KeyValueTreeArray &array)
        {
            if (array.isObjectArray())
            {
                for (const KeyValueTreeValue &value : array.values())
                {
                    assigner_.startSection(key.c_str());
                    assignSubTree(value.asObject());
                    assigner_.finishSection();
                }
            }
            else
            {
                assigner_.startOption(key.c_str());
                for (const KeyValueTreeValue &value : array.values())
                {
                    assigner_.appendValue(value.asVariant());
                }
                assigner_.finishOption();
            }
        }

        OptionsAssigner            assigner_;
        IKeyValueTreeErrorHandler *errorHandler_;
        KeyValueTreePath           context_;
};

class TreeIterationHelper : private OptionsVisitor
{
    public:
        TreeIterationHelper(const KeyValueTreeObject &root,
                            KeyValueTreeBuilder      *builder)
            : currentSourceObject_(&root),
              currentObjectBuilder_(builder->rootObject())
        {
        }

        void processOptionSection(const OptionSectionInfo &section)
        {
            OptionsIterator iterator(section);
            iterator.acceptOptions(this);
            iterator.acceptSections(this);
        }

    private:
        virtual void visitSection(const OptionSectionInfo &section)
        {
            const std::string &name          = section.name();
            auto               parentBuilder = currentObjectBuilder_;
            auto               parentObject  = currentSourceObject_;
            currentObjectBuilder_ = currentObjectBuilder_.addObject(name);
            currentSourceObject_  =
                (currentSourceObject_ != nullptr && currentSourceObject_->keyExists(name)
                 ? &(*currentSourceObject_)[name].asObject()
                 : nullptr);
            processOptionSection(section);
            currentSourceObject_  = parentObject;
            currentObjectBuilder_ = parentBuilder;
        }
        virtual void visitOption(const OptionInfo &option)
        {
            const std::string &name = option.name();
            if (currentSourceObject_ == nullptr || !currentSourceObject_->keyExists(name))
            {
                std::vector<Variant> values = option.defaultValues();
                if (values.size() == 1)
                {
                    currentObjectBuilder_.addRawValue(name, std::move(values[0]));
                }
                else if (values.size() > 1)
                {
                    auto arrayBuilder = currentObjectBuilder_.addArray(name);
                    for (Variant &value : values)
                    {
                        arrayBuilder.addRawValue(std::move(value));
                    }
                }
            }
            else
            {
                currentObjectBuilder_.addRawValue(name, KeyValueTreeValue((*currentSourceObject_)[name]));
            }
        }

        const KeyValueTreeObject  *currentSourceObject_;
        KeyValueTreeObjectBuilder  currentObjectBuilder_;
};

}   // namespace

//! \cond libapi

void assignOptionsFromKeyValueTree(Options                   *options,
                                   const KeyValueTreeObject  &tree,
                                   IKeyValueTreeErrorHandler *errorHandler)
{
    TreeAssignHelper helper(options, errorHandler);
    helper.assignAll(tree);
}

KeyValueTreeObject
adjustKeyValueTreeFromOptions(const KeyValueTreeObject &tree,
                              const Options            &options)
{
    KeyValueTreeBuilder builder;
    TreeIterationHelper helper(tree, &builder);
    helper.processOptionSection(options.rootSection());
    return builder.build();
}

//! \endcond

} // namespace gmx