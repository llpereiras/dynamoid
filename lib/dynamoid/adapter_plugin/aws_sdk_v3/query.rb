# frozen_string_literal: true

require_relative 'middleware/backoff'
require_relative 'middleware/limit'
require_relative 'middleware/start_key'
require_relative 'filter_expression_convertor'
require_relative 'projection_expression_convertor'

module Dynamoid
  # @private
  module AdapterPlugin
    class AwsSdkV3
      class Query
        OPTIONS_KEYS = %i[
          limit hash_key hash_value range_key consistent_read scan_index_forward
          select index_name batch_size exclusive_start_key record_limit scan_limit
          project
        ].freeze

        attr_reader :client, :table, :options, :conditions

        def initialize(client, table, opts = {})
          @client = client
          @table = table

          opts = opts.symbolize_keys
          @options = opts.slice(*OPTIONS_KEYS)
          @conditions = opts.except(*OPTIONS_KEYS)
        end

        def call
          request = build_request

          Enumerator.new do |yielder|
            api_call = lambda do |req|
              client.query(req).tap do |response|
                yielder << response
              end
            end

            middlewares = Middleware::Backoff.new(
              Middleware::StartKey.new(
                Middleware::Limit.new(api_call, record_limit: record_limit, scan_limit: scan_limit)
              )
            )

            catch :stop_pagination do
              loop do
                middlewares.call(request)
              end
            end
          end
        end

        private

        def build_request
          # expressions
          name_placeholder = +'#_a0'
          value_placeholder = +':_a0'

          name_placeholder_sequence = -> { name_placeholder.next!.dup }
          value_placeholder_sequence = -> { value_placeholder.next!.dup }

          name_placeholders = {}
          value_placeholders = {}

          # Deal with various limits and batching
          batch_size = options[:batch_size]
          limit = [record_limit, scan_limit, batch_size].compact.min

          # key condition expression
          convertor = FilterExpressionConvertor.new(key_conditions, name_placeholders, value_placeholders, name_placeholder_sequence, value_placeholder_sequence)
          key_condition_expression = convertor.expression
          value_placeholders = convertor.value_placeholders
          name_placeholders = convertor.name_placeholders

          # filter expression
          convertor = FilterExpressionConvertor.new(non_key_conditions, name_placeholders, value_placeholders, name_placeholder_sequence, value_placeholder_sequence)
          filter_expression = convertor.expression
          value_placeholders = convertor.value_placeholders
          name_placeholders = convertor.name_placeholders

          # projection expression
          convertor = ProjectionExpressionConvertor.new(options[:project], name_placeholders, name_placeholder_sequence)
          projection_expression = convertor.expression
          name_placeholders = convertor.name_placeholders

          request = options.slice(
            :consistent_read,
            :scan_index_forward,
            :select,
            :index_name,
            :exclusive_start_key
          ).compact

          request[:table_name]                  = table.name
          request[:limit]                       = limit                     if limit
          request[:key_condition_expression]    = key_condition_expression  if key_condition_expression.present?
          request[:filter_expression]           = filter_expression         if filter_expression.present?
          request[:expression_attribute_values] = value_placeholders        if value_placeholders.present?
          request[:expression_attribute_names]  = name_placeholders         if name_placeholders.present?
          request[:projection_expression]       = projection_expression     if projection_expression.present?

          request
        end

        def record_limit
          options[:record_limit]
        end

        def scan_limit
          options[:scan_limit]
        end

        def hash_key_name
          (options[:hash_key] || table.hash_key)
        end

        def range_key_name
          (options[:range_key] || table.range_key)
        end

        def key_conditions
          result = {}
          result[hash_key_name] = { eq: options[:hash_value].freeze }

          conditions.slice(*AwsSdkV3::RANGE_MAP.keys).each do |k, v|
            op = {
              range_greater_than: :gt,
              range_less_than:    :lt,
              range_gte:          :gte,
              range_lte:          :lte,
              range_begins_with:  :begins_with,
              range_between:      :between,
              range_eq:           :eq
            }[k]

            result[range_key_name] ||= {}
            result[range_key_name][op] = v
          end

          result
        end

        def non_key_conditions
          conditions.except(*AwsSdkV3::RANGE_MAP.keys)
        end
      end
    end
  end
end
