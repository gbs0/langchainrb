# frozen_string_literal: true

module Langchain
  class Assistant
    attr_reader :llm, :thread, :instructions
    attr_accessor :tools

    # Create a new assistant
    #
    # @param llm [Langchain::LLM::Base] The LLM instance to use for the assistant
    # @param thread [Langchain::Thread] The thread to use for the assistant
    # @param tools [Array<Langchain::Tool::Base>] The tools to use for the assistant
    # @param instructions [String] The instructions to use for the assistant
    def initialize(
      llm:,
      thread:,
      tools: [],
      instructions: nil
    )
      # Check that the LLM class implements the `chat()` instance method
      raise ArgumentError, "LLM must implement `chat()` method" unless llm.class.instance_methods(false).include?(:chat)
      raise ArgumentError, "Thread must be an instance of Langchain::Thread" unless thread.is_a?(Langchain::Thread)
      raise ArgumentError, "Tools must be an array of Langchain::Tool::Base instance(s)" unless tools.is_a?(Array) && tools.all? { |tool| tool.is_a?(Langchain::Tool::Base) }

      @llm = llm
      @thread = thread
      @tools = tools
      @instructions = instructions

      add_message(role: "system", content: instructions) if instructions
    end

    # Add a user message to the thread
    #
    # @param content [String] The content of the message
    # @param role [String] The role of the message
    # @param tool_calls [Array<Hash>] The tool calls to include in the message
    # @param tool_call_id [String] The ID of the tool call to include in the message
    def add_message(content: nil, role: "user", tool_calls: [], tool_call_id: nil)
      message = build_message(role: role, content: content, tool_calls: tool_calls, tool_call_id: tool_call_id)
      thread.add_message(message)
    end

    # Run the assistant
    #
    # @param auto_tool_execution [Boolean] Whether or not to automatically run tools
    # @return [Array<Langchain::Message>] The messages in the thread
    def run(auto_tool_execution: false)
      running = true

      while running
        # Do we need to determine if there's any unanswered tool calls?
        case (last_message = thread.messages.last).role
        when "system"
          # Raise error if there's only 1 message?
          # Do nothing
          running = false
        when "assistant"
          if last_message.tool_calls.any?
            if auto_tool_execution
              run_tools(last_message.tool_calls)
            else
              running = false
            end
          else
            # Do nothing
            running = false
          end
        when "user"
          # Run it!
          response = chat_with_llm

          if response.tool_calls
            running = true
            add_message(role: response.role, tool_calls: response.tool_calls)
          elsif response.chat_completion
            running = false
            add_message(role: response.role, content: response.chat_completion)
          end
        when "tool"
          # Run it!
          response = chat_with_llm
          running = true

          if response.tool_calls
            add_message(role: response.role, tool_calls: response.tool_calls)
          elsif response.chat_completion
            add_message(role: response.role, content: response.chat_completion)
          end
        end
      end

      thread.messages
    end

    # Add a user message to the thread and run the assistant
    #
    # @param content [String] The content of the message
    # @param auto_tool_execution [Boolean] Whether or not to automatically run tools
    # @return [Array<Langchain::Message>] The messages in the thread
    def add_message_and_run(content:, auto_tool_execution: false)
      add_message(content: content, role: "user")
      run(auto_tool_execution: auto_tool_execution)
    end

    # Submit tool output to the thread
    #
    # @param tool_call_id [String] The ID of the tool call to submit output for
    # @param output [String] The output of the tool
    # @return [Array<Langchain::Message>] The messages in the thread
    def submit_tool_output(tool_call_id:, output:)
      # TODO: Validate that `tool_call_id` is valid

      add_message(role: "tool", content: output, tool_call_id: tool_call_id)
    end

    private

    # Call to the LLM#chat() method
    #
    # @return [Langchain::LLM::BaseResponse] The LLM response object
    def chat_with_llm
      llm.chat(
        messages: thread.openai_messages,
        tools: tools.map(&:to_openai_tool),
        tool_choice: "auto"
      )
    end

    # Run the tools automatically
    #
    # @param tool_calls [Array<Hash>] The tool calls to run
    def run_tools(tool_calls)
      # Iterate over each function invocation and submit tool output
      # We may need to run this in a while() loop to handle subsequent tool invocations
      tool_calls.each do |tool_call|
        tool_call_id = tool_call.dig("id")
        tool_name = tool_call.dig("function", "name")
        tool_arguments = JSON.parse(tool_call.dig("function", "arguments"), symbolize_names: true)

        tool_instance = tools.find do |t|
          t.name == tool_name
        end or raise ArgumentError, "Tool not found in assistant.tools"

        output = tool_instance.execute(**tool_arguments)

        submit_tool_output(tool_call_id: tool_call_id, output: output)
      end

      response = chat_with_llm

      if response.tool_calls
        add_message(role: response.role, tool_calls: response.tool_calls)
      elsif response.chat_completion
        add_message(role: response.role, content: response.chat_completion)
      end
    end

    # Build a message
    #
    # @param role [String] The role of the message
    # @param content [String] The content of the message
    # @param tool_calls [Array<Hash>] The tool calls to include in the message
    # @param tool_call_id [String] The ID of the tool call to include in the message
    # @return [Langchain::Message] The Message object
    def build_message(role:, content: nil, tool_calls: [], tool_call_id: nil)
      Message.new(role: role, content: content, tool_calls: tool_calls, tool_call_id: tool_call_id)
    end

    # TODO: Fix this:
    def build_assistant_prompt(instructions:, tools:)
      while begin
        # Check if the prompt exceeds the context window
        # Return false to exit the while loop
        !llm.class.const_get(:LENGTH_VALIDATOR).validate_max_tokens!(
          thread.messages,
          llm.defaults[:chat_completion_model_name],
          {llm: llm}
        )
      # Rescue error if context window is exceeded and return true to continue the while loop
      rescue Langchain::Utils::TokenLength::TokenLimitExceeded
        true
      end
        # Truncate the oldest messages when the context window is exceeded
        thread.messages.shift
      end

      prompt
    end
  end
end