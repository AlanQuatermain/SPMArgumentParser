/*
 This project is based on part the Swift Package Manager project.
 The original bears the following disclaimer:

 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Foundation

fileprivate let removeDefaultRegex = try! NSRegularExpression(pattern: "\\[default: .+?\\]", options: [])

extension ArgumentParser {
    /// Generates part of a completion script for the given shell.
    ///
    /// These aren't complete scripts, as some setup code is required. See
    /// `Utilities/bash/completions` and `Utilities/zsh/_swift` for example
    /// usage.
    public func generateCompletionScript(for shell: Shell, on stream: OutputByteStream) {
        guard let commandName = commandName else { abort() }
        let name = "_\(commandName.replacingOccurrences(of: " ", with: "_"))"

        switch shell {
        case .bash:
            // Information about how to include this function in a completion script.
            stream <<< """
                # Generates completions for \(commandName)
                #
                # Parameters
                # - the start position of this parser; set to 1 if unknown

                """
            generateBashSwiftTool(name: name, on: stream)

        case .zsh:
            // Information about how to include this function in a completion script.
            stream <<< """
                # Generates completions for \(commandName)
                #
                # In the final compdef file, set the following file header:
                #
                #     #compdef \(name)
                #     local context state state_descr line
                #     typeset -A opt_args

                """
            generateZshSwiftTool(name: name, on: stream)

        case .fish:
            // Information about how to include this function in a completion script.
            stream <<< """
                # Generates completions for \(commandName)
                #

                """
            generateFishSwiftTool(name: name, on: stream)
        }
        stream.flush()
    }

    // MARK: - BASH

    fileprivate func generateBashSwiftTool(name: String, on stream: OutputByteStream) {
        stream <<< """
            function \(name)
            {

            """

        // Suggest positional arguments. Beware that this forces positional arguments
        // before options. For example [swift package pin <TAB>] expects a name as the
        // first argument. So no options (like --all) will be suggested. However after
        // the positional argument; [swift package pin MyPackage <TAB>] will list them
        // just fine.
        for (index, argument) in positionalArguments.enumerated() {
            stream <<< "    if [[ $COMP_CWORD == $(($1+\(index))) ]]; then\n"
            generateBashCompletion(argument, on: stream)
            stream <<< "    fi\n"
        }

        // Suggest subparsers in addition to other arguments.
        stream <<< "    if [[ $COMP_CWORD == $1 ]]; then\n"
        var completions = [String]()
        for (subName, _) in subparsers {
            completions.append(subName)
        }
        for option in optionArguments {
            completions.append(option.name)
            if let shortName = option.shortName {
                completions.append(shortName)
            }
        }
        stream <<< """
                    COMPREPLY=( $(compgen -W "\(completions.joined(separator: " "))" -- $cur) )
                    return
                fi

            """

        // Suggest completions based on previous word.
        generateBashCasePrev(on: stream)

        // Forward completions to subparsers.
        stream <<< "    case ${COMP_WORDS[$1]} in\n"
        for (subName, _) in subparsers {
            stream <<< """
                        (\(subName))
                            \(name)_\(subName) $(($1+1))
                            return
                        ;;

                """
        }
        stream <<< "    esac\n"

        // In all other cases (no positional / previous / subparser), suggest
        // this parser's completions.
        stream <<< """
                COMPREPLY=( $(compgen -W "\(completions.joined(separator: " "))" -- $cur) )
            }
            """

        for (subName, subParser) in subparsers {
            subParser.generateBashSwiftTool(name: "\(name)_\(subName)", on: stream)
        }
    }

    fileprivate func generateBashCasePrev(on stream: OutputByteStream) {
        stream <<< "    case $prev in\n"
        for argument in optionArguments {
            let flags = [argument.name] + (argument.shortName.map { [$0] } ?? [])
            stream <<< "        (\(flags.joined(separator: "|")))\n"
            generateBashCompletion(argument, on: stream)
            stream <<< "        ;;\n"
        }
        stream <<< "    esac\n"
    }

    fileprivate func generateBashCompletion(_ argument: AnyArgument, on stream: OutputByteStream) {
        switch argument.completion {
        case .none:
            // return; no value to complete
            stream <<< "            return\n"
        case .unspecified:
            break
        case .values(let values):
            let x = values.map({ $0.value }).joined(separator: " ")
            stream <<< """
                            COMPREPLY=( $(compgen -W "\(x)" -- $cur) )
                            return

                """
        case .filename:
            stream <<< """
                            _filedir
                            return

                """
        case .function(let name):
            stream <<< """
                            \(name)
                            return

                """
        }
    }

    // MARK: - ZSH

    fileprivate func generateZshSwiftTool(name: String, on stream: OutputByteStream) {
        // Completions are provided by zsh's _arguments builtin.
        stream <<< """
                \(name)() {
                    arguments=(

                """
        for argument in positionalArguments {
            stream <<< "        \""
            generateZshCompletion(argument, on: stream)
            stream <<< "\"\n"
        }
        for argument in optionArguments {
            generateZshArgument(argument, on: stream)
        }

        // Use a simple state-machine when dealing with subparsers.
        if subparsers.count > 0 {
            stream <<< """
                        '(-): :->command'
                        '(-)*:: :->arg'

                """
        }

        stream <<< """
                    )
                    _arguments $arguments && return

                """

        // Handle the state set by the state machine.
        if subparsers.count > 0 {
            stream <<< """
                    case $state in
                        (command)
                            local modes
                            modes=(

                """
            for (subName, subParser) in subparsers {
                stream <<< """
                                    '\(subName):\(subParser.overview)'

                    """
            }
            stream <<< """
                            )
                            _describe "mode" modes
                            ;;
                        (arg)
                            case ${words[1]} in

                """
            for (subName, _) in subparsers {
                stream <<< """
                                    (\(subName))
                                        \(name)_\(subName)
                                        ;;

                    """
            }
            stream <<< """
                            esac
                            ;;
                    esac

                """
        }
        stream <<< "}\n\n"

        for (subName, subParser) in subparsers {
            subParser.generateZshSwiftTool(name: "\(name)_\(subName)", on: stream)
        }
    }

    fileprivate func generateZshArgument(_ argument: AnyArgument, on stream: OutputByteStream) {
        stream <<< "        \""
        switch argument.shortName {
        case .none: stream <<< "\(argument.name)"
        case let shortName?: stream <<< "(\(argument.name) \(shortName))\"{\(argument.name),\(shortName)}\""
        }

        let description = removeDefaultRegex
            .replace(in: argument.usage ?? "", with: "")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        stream <<< "[\(description)]"

        generateZshCompletion(argument, on: stream)
        stream <<< "\"\n"
    }

    fileprivate func generateZshCompletion(_ argument: AnyArgument, on stream: OutputByteStream) {
        let message = removeDefaultRegex
            .replace(in: argument.usage ?? "", with: "")
            .replacingOccurrences(of: "\"", with: "\\\"")

        switch argument.completion {
        case .none: stream <<< ":\(message): "
        case .unspecified: break
        case .filename: stream <<< ":\(message):_files"
        case .values(let values):
            stream <<< ": :{_values ''"
            for (value, description) in values {
                stream <<< " '\(value)[\(description)]'"
            }
            stream <<< "}"
        case .function(let name): stream <<< ":\(message):\(name)"
        }
    }

    // MARK: - Fish

    fileprivate func generateFishSwiftTool(name: String, on stream: OutputByteStream) {
        let hasSubcommands = self.subparsers.count > 0
        if hasSubcommands {
            generateFishSubcommandFilters(name: name, on: stream)
        }

        // Generate completions for the basic options at this level.
        for argument in optionArguments {
            generateFishCompletion(argument, for: name, on: stream)
        }

        // Fish completion doesn't seem to have any way to offer completions for positional options...

        // Generate subparsers.
        for (subname, subparser) in subparsers {
            generateFishSubparserCompletions(commandName: name, subname: subname, parser: subparser, on: stream)
        }
    }

    fileprivate func generateFishSubcommandFilters(name: String, on stream: OutputByteStream) {
        stream <<< """
            function __fish_\(name)_needs_command
                # Figure out if the current invocation already has a command.
                # Any options defined at this level may appear before the command.
                set -l opts \(generateFishOptsList(optionArguments))
                set cmd (commandline -opc)
                set -e cmd[1]
                # Eat options defined above, leaving $argv[1] containing first unlisted parameter.
                argparse -s $opts -- $cmd 2>/dev/null
                or return 0 # in which case, nothing remaining after eating thos options.

                # if the first value in remaining arg list is set, this is a subcommand.
                if set -q argv[1]
                    # Also print the command, so this can be used to figure out what it is.
                    echo $argv[1]
                    return 1
                end
                return 0
            end

            function __fish_\(name)_using_command
                set -l cmd (__fish_\(name)_needs_command)
                test -z "$cmd"; and return 1
                contains -- $cmd $argv; and return 0
                return 1
            end


            """
    }

    fileprivate func generateFishCompletion(_ argument: AnyArgument, for name: String, on stream: OutputByteStream) {
        let requiresArgument = argument.kind == Bool.self && argument.strategy == .oneByOne
        let fileExclusiveArg: String
        if case .filename = argument.completion {
            // allow filenames
            fileExclusiveArg = ""
        } else if requiresArgument {
            // no filenames, requires argument == 'exclusive'
            fileExclusiveArg = " -x"
        } else {
            // no filenames
            fileExclusiveArg = " -f"
        }

        stream <<< "complete\(fileExclusiveArg) -c \(name) -n '__fish_\(name)_needs_command'"
        if let shortName = argument.shortName {
            stream <<< " -s \(shortName)"
        }
        stream <<< " -l \(name)"
        if requiresArgument {
            stream <<< " -r"
        }

        if case let .values(values) = argument.completion {
            stream <<< " -a \"\(values.map({ $0.0 }).joined(separator: " "))\""
        }
        if let usage = argument.usage {
            let description = removeDefaultRegex
                .replace(in: usage, with: "")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "(", with: "\\(")
                .replacingOccurrences(of: ")", with: "\\)")
            stream <<< " -d \"\(description)\""
        }
    }

    fileprivate func generateFishOptsList(_ arguments: [AnyArgument]) -> [String] {
        // Fish shell's `argparse` format requires that we specify unique short names
        // for each option, even when using them to say "no short names should work". Sigh.
        let lowercase = "abcdefghijklmnopqrstuvwxyz"
        let uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        var availableCharacters = Set<Character>(lowercase)
        availableCharacters.formUnion(uppercase)

        var completions = [String]()
        let optionsWithShortNames = arguments.filter { $0.shortName != nil }
        let optionsWithoutShortNames = arguments.filter { $0.shortName == nil }

        for argument in optionsWithShortNames {
            guard availableCharacters.contains(argument.shortName!.first!) else {
                fatalError("Short name is already in use: \(argument.shortName!)")
            }
            var str = "\(argument.shortName!)/\(argument.name)"
            availableCharacters.remove(argument.shortName!.first!)

            if argument.kind != Bool.self {
                str += "="
            } else if argument.isArray {
                str += "=+"
            } else if argument.isOptional {
                str += "=?"
            }

            completions.append(str)
        }
        // assign the remaininder with 'fake' short names to be ignored
        var idx = availableCharacters.startIndex
        for argument in optionsWithoutShortNames {
            guard idx != availableCharacters.endIndex else {
                fatalError("Ran out of unique synthetic short-name characters!")
            }
            var str = "\(availableCharacters[idx])-\(argument.name)"

            if argument.kind != Bool.self {
                str += "="
            } else if argument.isArray {
                str += "=+"
            } else if argument.isOptional {
                str += "=?"
            }

            completions.append(str)
            idx = availableCharacters.index(after: idx)
        }

        return completions
    }

    fileprivate func generateFishSubparserCompletions(commandName: String, subname: String, parents: [String] = [],
                                                      parser: ArgumentParser, on stream: OutputByteStream) {
        // Completion for the subparser command itself.
        
    }
}

fileprivate extension NSRegularExpression {
    func replace(in original: String, with replacement: String) -> String {
        return stringByReplacingMatches(in: original, options: [],
                                        range: NSRange(location: 0, length: original.count),
                                        withTemplate: replacement)
    }
}
