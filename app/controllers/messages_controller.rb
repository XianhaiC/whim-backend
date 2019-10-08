class MessagesController < ApplicationController
  before_action :attempt_login, only: [:create]
  before_action :authenticate_session, only: [:create]

  def create
    # authenticate spark before creating message
    authenticate_spark_session(Spark.find(params[:spark_id]))

    message = Message.new(message_params)
    parent_thread = MessageThread.find(params[:parent_thread_id])

    if !message.save
      return render json: { errors: message.errors }, status: 400
    end

    serialized_data = ActiveModelSerializers::Adapter::Json.new(
      MessageSerializer.new(message)).serializable_hash

    thread_data = {}
    # create a thread for the message if it's an inspiration
    if message.is_inspiration
      thread = MessageThread.new(impulse_id: params[:impulse_id],
                                 parent: message)
      if !thread.save
        return render json: { errors: thread.errors }, status: 400
      end

      thread_data = ActiveModelSerializers::Adapter::Json.new(
        MessageThreadSerializer.new(thread)).serializable_hash
    end

    serialized_data = ActiveModelSerializers::Adapter::Json.new(
      MessageSerializer.new(message)).serializable_hash.merge(thread_data)

    MessageThreadsChannel.broadcast_to parent_thread, serialized_data
    head :ok
  end

  def update
    message = Message.find(params[:id])

    if message.nil?
      return render json: {
        errors:["Message does not exist"] }, status: 400
    end

    parent_thread = MessageThread.find(message.parent_thread_id)
    message.body = params[:body]
    if message.save
      serialized_data = ActiveModelSerializers::Adapter::Json.new(
        MessageSerializer.new(message)).serializable_hash
      MessageThreadsChannel.broadcast_to parent_thread, serialized_data
      head :ok
    else
      render json: { errors: message.errors }, status: 400
    end
  end

  def destroy
    message = Message.find(params[:id])

    # delete its thread and thread messages first
    if message.is_inspiration
      thread = message.own_thread
      thread.delete
    end

    message.delete

    serialized_data = ActiveModelSerializers::Adapter::Json.new(
      MessageSerializer.new(message)).serializable_hash.merge({ deleted: true })
    MessageThreadsChannel.broadcast_to message.parent_thread, serialized_data
    head :ok
  end

  private
    def message_params
      params.require(:message).permit(:body, :spark_id,
                                      :impulse_id, :parent_thread_id, :is_inspiration)
    end

    def authenticate_spark_session(spark)
      if spark.account.nil?
        # authenticate via token verification
        if spark.session_token != @current_session_token
          render json: { errors: ['Spark not authenticated: Token mismatch'] },
            status: :unauthorized
        end
      elsif @current_account.nil?
        render json: { errors: ['Spark not authenticated: Spark linked, but not logged in'] },
          status: :unauthorized
      elsif !@current_account.nil? &&
        @current_account.id.to_i != spark.account.id.to_i
        # authenticate via account link verification
        render json: { errors: ['Spark not authenticated: Spark does not belong to account'] },
          status: :unauthorized
      end
    end
end
